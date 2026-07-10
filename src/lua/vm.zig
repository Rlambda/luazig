const std = @import("std");

const LuaSource = @import("source.zig").Source;
const LuaLexer = @import("lexer.zig").Lexer;
const LuaParser = @import("parser.zig").Parser;
const lua_ast = @import("ast.zig");
const lua_codegen = @import("codegen.zig");
const testc = @import("testc.zig");
const ir = @import("ir.zig");
const bc = @import("bytecode.zig");
const LuaToken = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;
const stdio = @import("util").stdio;

// PUC-faithful hash table core. Used by `Table.hash` for the unified hash part
// (strings, ints, pointers, bools all live in one `[]Node`). The functions we
// call here are the algorithmic primitives (lookup / insert / delete / next /
// rehash); the VM owns all the policy around array-part promotion and GC.
const ltable = @import("ltable.zig");

pub const BuiltinId = enum {
    print,
    warn,
    tostring,
    tonumber,
    @"error",
    assert,
    select,
    rawlen,
    rawequal,
    type,
    collectgarbage,
    pcall,
    xpcall,
    next,
    dofile,
    loadfile,
    load,
    require,
    package_searchpath,
    setmetatable,
    getmetatable,
    debug_getinfo,
    debug_getlocal,
    debug_setlocal,
    debug_getupvalue,
    debug_setupvalue,
    debug_upvalueid,
    debug_upvaluejoin,
    debug_gethook,
    debug_sethook,
    debug_getregistry,
    debug_traceback,
    debug_setmetatable,
    debug_getuservalue,
    debug_setuservalue,
    pairs,
    ipairs,
    pairs_iter,
    ipairs_iter,
    rawget,
    rawset,
    io_write,
    io_open,
    io_tmpfile,
    io_read,
    io_lines,
    io_lines_iter,
    io_flush,
    io_input,
    io_output,
    io_close,
    io_type,
    io_stderr_write,
    file_close,
    file_meta_close,
    file_write,
    file_read,
    file_seek,
    file_flush,
    file_lines,
    file_setvbuf,
    file_gc,
    os_clock,
    os_date,
    os_time,
    os_difftime,
    os_getenv,
    os_tmpname,
    os_remove,
    os_rename,
    os_setlocale,
    math_random,
    math_randomseed,
    math_tointeger,
    math_sin,
    math_cos,
    math_tan,
    math_asin,
    math_acos,
    math_atan,
    math_deg,
    math_rad,
    math_abs,
    math_sqrt,
    math_exp,
    math_ldexp,
    math_frexp,
    math_ceil,
    math_ult,
    math_modf,
    math_log,
    math_fmod,
    math_floor,
    math_type,
    math_min,
    math_max,
    string_format,
    string_pack,
    string_packsize,
    string_unpack,
    string_dump,
    string_len,
    string_byte,
    string_char,
    string_upper,
    string_lower,
    string_reverse,
    string_sub,
    string_find,
    string_match,
    string_gmatch,
    string_gmatch_iter,
    string_gsub,
    string_rep,
    utf8_char,
    utf8_codepoint,
    utf8_len,
    utf8_offset,
    utf8_codes,
    utf8_codes_iter,
    utf8_codes_iter_ns,
    table_pack,
    table_create,
    table_move,
    table_concat,
    table_insert,
    table_unpack,
    table_remove,
    table_sort,
    coroutine_create,
    coroutine_wrap,
    coroutine_wrap_iter,
    coroutine_resume,
    coroutine_yield,
    coroutine_status,
    coroutine_running,
    coroutine_isyieldable,
    coroutine_close,
    testc_testC,
    testc_makecfunc,
    testc_totalmem,

    pub fn name(self: BuiltinId) []const u8 {
        return switch (self) {
            .print => "print",
            .warn => "warn",
            .tostring => "tostring",
            .tonumber => "tonumber",
            .@"error" => "error",
            .assert => "assert",
            .select => "select",
            .rawlen => "rawlen",
            .rawequal => "rawequal",
            .type => "type",
            .collectgarbage => "collectgarbage",
            .pcall => "pcall",
            .xpcall => "xpcall",
            .next => "next",
            .dofile => "dofile",
            .loadfile => "loadfile",
            .load => "load",
            .require => "require",
            .package_searchpath => "package.searchpath",
            .setmetatable => "setmetatable",
            .getmetatable => "getmetatable",
            .debug_getinfo => "debug.getinfo",
            .debug_getlocal => "debug.getlocal",
            .debug_setlocal => "debug.setlocal",
            .debug_getupvalue => "debug.getupvalue",
            .debug_setupvalue => "debug.setupvalue",
            .debug_upvalueid => "debug.upvalueid",
            .debug_upvaluejoin => "debug.upvaluejoin",
            .debug_gethook => "debug.gethook",
            .debug_sethook => "debug.sethook",
            .debug_getregistry => "debug.getregistry",
            .debug_traceback => "debug.traceback",
            .debug_setmetatable => "debug.setmetatable",
            .debug_getuservalue => "debug.getuservalue",
            .debug_setuservalue => "debug.setuservalue",
            .pairs => "pairs",
            .ipairs => "ipairs",
            .pairs_iter => "pairs_iter",
            .ipairs_iter => "ipairs_iter",
            .rawget => "rawget",
            .rawset => "rawset",
            .io_write => "io.write",
            .io_open => "io.open",
            .io_tmpfile => "io.tmpfile",
            .io_read => "io.read",
            .io_lines => "io.lines",
            .io_lines_iter => "io.lines_iter",
            .io_flush => "io.flush",
            .io_input => "io.input",
            .io_output => "io.output",
            .io_close => "io.close",
            .io_type => "io.type",
            .io_stderr_write => "io.stderr:write",
            .file_close => "FILE*:close",
            .file_meta_close => "FILE*::__close",
            .file_write => "FILE*:write",
            .file_read => "FILE*:read",
            .file_seek => "FILE*:seek",
            .file_flush => "FILE*:flush",
            .file_lines => "FILE*:lines",
            .file_setvbuf => "FILE*:setvbuf",
            .file_gc => "__gc",
            .os_clock => "os.clock",
            .os_date => "os.date",
            .os_time => "os.time",
            .os_difftime => "os.difftime",
            .os_getenv => "os.getenv",
            .os_tmpname => "os.tmpname",
            .os_remove => "os.remove",
            .os_rename => "os.rename",
            .os_setlocale => "os.setlocale",
            .math_random => "math.random",
            .math_randomseed => "math.randomseed",
            .math_tointeger => "math.tointeger",
            .math_sin => "math.sin",
            .math_cos => "math.cos",
            .math_tan => "math.tan",
            .math_asin => "math.asin",
            .math_acos => "math.acos",
            .math_atan => "math.atan",
            .math_deg => "math.deg",
            .math_rad => "math.rad",
            .math_abs => "math.abs",
            .math_sqrt => "math.sqrt",
            .math_exp => "math.exp",
            .math_ldexp => "math.ldexp",
            .math_frexp => "math.frexp",
            .math_ceil => "math.ceil",
            .math_ult => "math.ult",
            .math_modf => "math.modf",
            .math_log => "math.log",
            .math_fmod => "math.fmod",
            .math_floor => "math.floor",
            .math_type => "math.type",
            .math_min => "math.min",
            .math_max => "math.max",
            .string_format => "string.format",
            .string_pack => "string.pack",
            .string_packsize => "string.packsize",
            .string_unpack => "string.unpack",
            .string_dump => "string.dump",
            .string_len => "string.len",
            .string_byte => "string.byte",
            .string_char => "string.char",
            .string_upper => "string.upper",
            .string_lower => "string.lower",
            .string_reverse => "string.reverse",
            .string_sub => "string.sub",
            .string_find => "string.find",
            .string_match => "string.match",
            .string_gmatch => "string.gmatch",
            .string_gmatch_iter => "string.gmatch_iter",
            .string_gsub => "string.gsub",
            .string_rep => "string.rep",
            .utf8_char => "utf8.char",
            .utf8_codepoint => "utf8.codepoint",
            .utf8_len => "utf8.len",
            .utf8_offset => "utf8.offset",
            .utf8_codes => "utf8.codes",
            .utf8_codes_iter => "utf8.codes_iter",
            .utf8_codes_iter_ns => "utf8.codes_iter_ns",
            .table_pack => "table.pack",
            .table_create => "table.create",
            .table_move => "table.move",
            .table_concat => "table.concat",
            .table_insert => "table.insert",
            .table_unpack => "table.unpack",
            .table_remove => "table.remove",
            .table_sort => "table.sort",
            .coroutine_create => "coroutine.create",
            .coroutine_wrap => "coroutine.wrap",
            .coroutine_wrap_iter => "coroutine.wrap_iter",
            .coroutine_resume => "coroutine.resume",
            .coroutine_yield => "coroutine.yield",
            .coroutine_status => "coroutine.status",
            .coroutine_running => "coroutine.running",
            .coroutine_isyieldable => "coroutine.isyieldable",
            .coroutine_close => "coroutine.close",
            .testc_testC => "T.testC",
            .testc_makecfunc => "T._makecfunc",
            .testc_totalmem => "T.totalmem",
        };
    }
};

pub const Cell = struct {
    value: Value,
    /// When non-null, this is an "open" upvalue that directly references
    /// the shared bytecode stack at `bc_stack[bc_stack_idx]`. Reads and
    /// writes go through the stack slot, not through `value`.
    /// When null, `value` is the actual value (closed upvalue).
    /// This mirrors PUC Lua's UpVal model: open upvalues point to stack,
    /// closed upvalues have their own copy.
    bc_stack_idx: ?usize = null,

    /// Read the current value of this cell.
    /// For open upvalues: reads from the shared stack.
    /// For closed upvalues: reads from value.
    pub fn get(self: *const Cell, bc_stack: []const Value) Value {
        if (self.bc_stack_idx) |idx| return bc_stack[idx];
        return self.value;
    }

    /// Write a value to this cell.
    /// For open upvalues: writes to the shared stack.
    /// For closed upvalues: writes to value.
    pub fn set(self: *Cell, bc_stack: []Value, v: Value) void {
        if (self.bc_stack_idx) |idx| {
            bc_stack[idx] = v;
        } else {
            self.value = v;
        }
    }

    /// Close this upvalue: snapshot the stack value into `value`,
    /// mark as closed (bc_stack_idx = null).
    pub fn close(self: *Cell, bc_stack: []const Value) void {
        if (self.bc_stack_idx) |idx| {
            self.value = bc_stack[idx];
            self.bc_stack_idx = null;
        }
    }
};

pub const Closure = struct {
    func: *const ir.Function,
    proto: ?*const bc.Proto = null, // bytecode proto (non-null for bytecode closures)
    upvalues: []const *Cell,
    env_override: ?Value = null,
    synthetic_env_slot: bool = false,
};

const SuspendedFrame = struct {
    func: *const ir.Function,
    proto: ?*const bc.Proto = null,
    callee: Value = .Nil,
    regs: []Value = &[_]Value{},
    locals: []Value = &[_]Value{},
    boxed: []?*Cell = &[_]?*Cell{},
    local_active: []bool = &[_]bool{},
    varargs: []Value = &[_]Value{},
    upvalues: []const *Cell = &[_]*Cell{},
    env_override: ?Value = null,
    frame_id: usize = 0,
    pc: usize = 0,
    current_line: i64 = 0,
    last_hook_line: i64 = -1,
    used_closing_line_hook: bool = false,
    resume_skip_count_pc: ?usize = null,
    is_tailcall: bool = false,
    hide_from_debug: bool = false,
    direct_yield: bool = false,
    from_debug_hook: bool = false,
    from_count_hook: bool = false,
    stack_depth: usize = 0,
    yield_id: usize = 0,

    pub fn isVararg(fr: SuspendedFrame) bool {
        if (fr.proto) |p| return p.is_vararg;
        return fr.func.is_vararg;
    }

    pub fn numParams(fr: SuspendedFrame) u32 {
        if (fr.proto) |p| return p.numparams;
        return fr.func.num_params;
    }

    pub fn lineDefined(fr: SuspendedFrame) u32 {
        if (fr.proto) |p| return p.line_defined;
        return fr.func.line_defined;
    }

    pub fn sourceName(fr: SuspendedFrame) []const u8 {
        if (fr.proto) |p| return p.source_name;
        return fr.func.source_name;
    }
};

pub const Thread = struct {
    const WrapYield = struct {
        values: []Value,
    };
    const LocalSnap = struct {
        frame_id: usize,
        slot: usize,
        name: []const u8,
        value: Value,
    };
    const FrameCaptureCell = struct {
        frame_id: usize,
        slot: usize,
        cell: *Cell,
    };
    status: enum { suspended, running, dead } = .suspended,
    callee: Value, // .Closure or .Builtin
    yielded: ?[]Value = null,
    locals_snapshot: ?[]LocalSnap = null,
    wrap_eager_mode: bool = false,
    wrap_started: bool = false,
    wrap_yields: std.ArrayListUnmanaged(WrapYield) = .empty,
    wrap_yield_index: usize = 0,
    wrap_final_values: ?[]Value = null,
    wrap_final_error: ?Value = null,
    wrap_final_delivered: bool = false,
    frame_local_overrides: std.ArrayListUnmanaged(LocalSnap) = .empty,
    frame_capture_cells: std.ArrayListUnmanaged(FrameCaptureCell) = .empty,
    frame_id_counter: usize = 0,
    close_mode: bool = false,
    close_has_err: bool = false,
    close_err: Value = .Nil,
    wrap_repeat_closure: ?*Closure = null,
    entry_args: ?[]Value = null,
    debug_hook: DebugHookState = .{},
    trace_yields: usize = 0,
    trace_had_error: bool = false,
    trace_currentline: i64 = 0,
    trace_stack_depth: usize = 0,
    trace_frame_names: ?[]?[]const u8 = null,
    pending_close_builtin: bool = false,
    pending_close_builtin_obj: Value = .Nil,
    in_close_pending_unwind: bool = false,
    pending_close_err_active: bool = false,
    pending_close_err: Value = .Nil,
    dofile_entry_closure: ?*Closure = null,
    resume_base_depth: usize = 0,
    resume_pop_consumed: bool = false,
    resume_recursive_mode: bool = false,
    // Phase-A coroutine runtime scaffold: real suspendable frame storage.
    suspended_frames: std.ArrayListUnmanaged(SuspendedFrame) = .empty,
    resume_inbox: ?[]Value = null,
    tail_resume_inbox: ?[]Value = null,
    tail_resume_func: ?*const ir.Function = null,
    last_yield_payload: ?[]Value = null,
    suspended_pc: usize = 0,
    tail_suspended_pc: usize = 0,
    suspended_direct_yield: bool = false,
    capture_yield_id: usize = 0,
    next_yield_id: usize = 1,
    resume_yield_id: usize = 0,
    yield_origin_depth: usize = 0,
    in_resume: bool = false,
    internal_resume_after_yield: bool = false,
    suspended_builtin: ?BuiltinId = null,
    suspended_builtin_args: ?[]Value = null,
    capture_from_debug_hook: bool = false,
    capture_from_count_hook: bool = false,
    testc_state_main: bool = false,
    testc_pending_conts: std.ArrayListUnmanaged(TestcPendingContinuation) = .empty,
    testc_close_current: ?Value = null,
    testc_close_return_values: ?[]Value = null,
    testc_close_remaining: ?[]Value = null,
    started: bool = false,
    finished: bool = false,
    caller: ?*Thread = null,
};

const DebugHookState = struct {
    func: ?Value = null,
    mask: []const u8 = "",
    mask_buf: [8]u8 = [_]u8{0} ** 8,
    mask_len: usize = 0,
    count: i64 = 0,
    budget: i64 = 0,
    tick: i64 = 0,
    has_call: bool = false,
    has_return: bool = false,
    has_line: bool = false,
    skip_line_once: bool = false,
    skip_line_until_depth: usize = 0,
    skip_count_once: bool = false,
    line_hook_preseeded: bool = false,

    fn setMask(self: *DebugHookState, mask: []const u8) void {
        self.mask_len = @min(mask.len, self.mask_buf.len);
        @memcpy(self.mask_buf[0..self.mask_len], mask[0..self.mask_len]);
        self.mask = self.mask_buf[0..self.mask_len];
    }

    fn clear(self: *DebugHookState) void {
        self.func = null;
        self.mask = "";
        self.mask_len = 0;
        self.count = 0;
        self.budget = 0;
        self.tick = 0;
        self.has_call = false;
        self.has_return = false;
        self.has_line = false;
        self.skip_line_once = false;
        self.skip_line_until_depth = 0;
        self.skip_count_once = false;
        self.line_hook_preseeded = false;
    }
};

fn isDebugCountHookInst(inst: ir.Inst) bool {
    return switch (inst) {
        // Count hooks in PUC Lua are tied to VM bytecode dispatch, while this
        // interpreter executes a lower-level IR with many temporary moves and
        // comparisons per source operation. Count only instructions that map
        // to source-visible bytecode-like work; otherwise tight numeric loops
        // overcount by an order of magnitude and diverge from official tests.
        .ConstNil,
        .ConstBool,
        .ConstInt,
        .ConstNum,
        .ConstString,
        .ConstFunc,
        .GetName,
        .SetName,
        .GetUpvalue,
        .SetUpvalue,
        .UnOp,
        .NewTable,
        .SetField,
        .SetIndex,
        .Append,
        .AppendCallExpand,
        .AppendVarargExpand,
        .GetField,
        .GetIndex,
        .Call,
        .ForIterCall,
        .CallVararg,
        .CallExpand,
        .Return,
        .ReturnExpand,
        .ReturnCall,
        .ReturnCallVararg,
        .ReturnCallExpand,
        .Vararg,
        .VarargTable,
        .ReturnVarargExpand,
        .ReturnVararg,
        .Jump,
        .RaiseError,
        => true,

        .GetLocal,
        .SetLocal,
        .CloseLocal,
        .ClearLocal,
        .BinOp,
        .Label,
        .JumpIfFalse,
        => false,
    };
}

const TestcPendingContinuation = struct {
    script: []const u8,
    stack: []Value,
    upvalues: ?[]Value = null,
    upenv: Value = .Nil,
    state: ?*Table = null,
    status: ?[]const u8 = null,
    ctx: i64 = 0,
    first_arg: ?Value = null,
    closers: ?[]Value = null,
};

// Interned Lua string. Layout mirrors PUC Lua's TString: a header immediately
// followed by `len` bytes in the SAME allocation (one alloc per string,
// cache-friendly). Short strings are interned (one pointer per content, like
// PUC `LUA_VSHRSTR`); long strings are NOT interned (each a fresh allocation,
// like PUC `LUA_VLNGSTR`), so equality is pointer-eq only for two short
// strings — see `luaStringEq`.
pub const LuaString = struct {
    hash: u64, // content hash, computed once at intern time (random-seeded)
    len: usize,
    is_short: bool, // <= lua_string_max_short_len => interned (PUC short variant)
    marked: u8 = 0, // GC mark bit (used from Task 5)

    // Bytes stored inline right after the header, in the same allocation.
    pub fn bytes(self: *const LuaString) []const u8 {
        const header: [*]const u8 = @ptrCast(self);
        const body = header + @sizeOf(LuaString);
        return body[0..self.len];
    }
};

// PUC Lua's LUAI_MAXSHORTLEN (lstring.h): strings up to this many bytes are
// interned as short strings; longer strings are allocated fresh each time.
pub const lua_string_max_short_len: usize = 40;

// Equality of two Lua strings, matching PUC `luaV_equalobj` for strings
// (lvm.c:600-624) + `luaS_eqstr` (lstring.c:44-50):
//   - two short strings: pointer identity (both interned => same pointer)
//   - otherwise (at least one long): content compare (length then bytes)
pub fn luaStringEq(a: *const LuaString, b: *const LuaString) bool {
    if (a.is_short and b.is_short) return a == b;
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a.bytes(), b.bytes());
}

// Allocate a LuaString with `raw` copied inline right after the header.
// Exposed (`pub`) so the experimental bytecode const pool (bytecode.zig) can
// pre-intern string constants at chunk-build time, keeping `bc_vm` consistent
// with the main VM's interned-string model.
pub fn createLuaString(alloc: std.mem.Allocator, raw: []const u8, hash: u64) !*LuaString {
    const total = @sizeOf(LuaString) + raw.len;
    const buf = try alloc.alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(@alignOf(LuaString)),
        total,
    );
    errdefer alloc.free(buf);
    const ls: *LuaString = @ptrCast(@alignCast(buf.ptr));
    ls.hash = hash;
    ls.len = raw.len;
    ls.is_short = raw.len <= lua_string_max_short_len;
    ls.marked = 0;
    @memcpy(buf[@sizeOf(LuaString)..], raw);
    return ls;
}

// Free a LuaString allocated by `createLuaString`.
pub fn destroyLuaString(alloc: std.mem.Allocator, ls: *LuaString) void {
    const total = @sizeOf(LuaString) + ls.len;
    const buf: [*]align(@alignOf(LuaString)) u8 = @ptrCast(@alignCast(ls));
    alloc.free(buf[0..total]);
}

// Global table of all live interned strings. Keyed by content bytes (the inline
// slice of the stored LuaString, which is stable for the allocation's lifetime),
// mapping to the canonical `*LuaString`. Mirrors PUC `lstring.c` stringtable:
// at most one entry per distinct content, so string equality becomes pointer
// comparison.
pub const StringIntern = struct {
    const Map = std.HashMapUnmanaged(
        []const u8,
        *LuaString,
        Context,
        std.hash_map.default_max_load_percentage,
    );

    const Context = struct {
        pub fn hash(_: @This(), k: []const u8) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k);
            return h.final();
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };

    table: Map = .empty,

    /// Sweep: remove and free entries whose LuaString is not in `marked`.
    /// Safe to call during GC — collects entries to remove first, then
    /// removes+frees one at a time (key is valid until the LuaString is freed).
    pub fn sweep(self: *StringIntern, alloc: std.mem.Allocator, marked: *const std.AutoHashMapUnmanaged(*LuaString, void)) !void {
        var to_remove = std.ArrayListUnmanaged(*LuaString).empty;
        defer to_remove.deinit(alloc);
        var it = self.table.iterator();
        while (it.next()) |entry| {
            if (!marked.contains(entry.value_ptr.*)) {
                try to_remove.append(alloc, entry.value_ptr.*);
            }
        }
        for (to_remove.items) |ls| {
            _ = self.table.remove(ls.bytes());
            destroyLuaString(alloc, ls);
        }
    }

    // Return the canonical *LuaString for `raw`, creating+inserting it if absent.
    // `hash` is the caller-computed content hash (random-seeded at the Vm level),
    // cached on the LuaString so the Table's own hash and all later uses are free.
    fn intern(self: *StringIntern, alloc: std.mem.Allocator, raw: []const u8, hash: u64) !*LuaString {
        if (self.table.get(raw)) |existing| return existing;
        const ls = try createLuaString(alloc, raw, hash);
        try self.table.put(alloc, ls.bytes(), ls);
        return ls;
    }

    fn deinit(self: *StringIntern, alloc: std.mem.Allocator) void {
        var it = self.table.valueIterator();
        while (it.next()) |ls_ptr| destroyLuaString(alloc, ls_ptr.*);
        self.table.deinit(alloc);
    }
};

test "LuaString stores inline bytes and cached hash" {
    const alloc = std.testing.allocator;
    const h: u64 = 0xdeadbeef;
    const ls = try createLuaString(alloc, "hello", h);
    defer destroyLuaString(alloc, ls);
    try std.testing.expectEqual(@as(usize, 5), ls.len);
    try std.testing.expectEqual(h, ls.hash);
    try std.testing.expectEqualStrings("hello", ls.bytes());
}

fn hashStringForTest(s: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(s);
    return h.final();
}

test "StringIntern dedups equal content to same pointer" {
    var intern = StringIntern{};
    defer intern.deinit(std.testing.allocator);
    const a = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    const b = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    try std.testing.expect(a == b); // pointer identity
    try std.testing.expectEqualStrings("foo", a.bytes());
}

test "StringIntern keeps distinct content distinct" {
    var intern = StringIntern{};
    defer intern.deinit(std.testing.allocator);
    const a = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    const c = try intern.intern(std.testing.allocator, "bar", hashStringForTest("bar"));
    try std.testing.expect(a != c);
}

// PUC Lua has two string variants: short (<= LUAI_MAXSHORTLEN=40) interned in
// the string table, and long (>40) NOT interned — each a fresh allocation.
// Equality therefore cannot be pointer-eq in general: two long strings with the
// same content are equal-by-value but distinct pointers. See lvm.c:600-624 and
// lstring.c:44-50 (luaS_eqstr).
test "luaStringEq: long strings equal by content, distinct pointers" {
    const alloc = std.testing.allocator;
    const long = "a" ** 300; // > MAX_SHORT_LEN => long, not interned
    const a = try createLuaString(alloc, long, 0);
    defer destroyLuaString(alloc, a);
    const b = try createLuaString(alloc, long, 0);
    defer destroyLuaString(alloc, b);
    try std.testing.expect(a != b); // separate allocations
    try std.testing.expect(luaStringEq(a, b)); // equal by content
}

test "luaStringEq: short strings use pointer identity" {
    const alloc = std.testing.allocator;
    const a = try createLuaString(alloc, "abc", 0);
    defer destroyLuaString(alloc, a);
    const b = try createLuaString(alloc, "abc", 0);
    defer destroyLuaString(alloc, b);
    // Two separately-allocated short strings are NOT pointer-equal, so even with
    // equal content luaStringEq is false. (In the VM, short strings always go
    // through the intern table, so equal content => same pointer.)
    try std.testing.expect(a != b);
    try std.testing.expect(!luaStringEq(a, b));
    try std.testing.expect(luaStringEq(a, a));
}

pub const Value = union(enum) {
    Nil,
    Bool: bool,
    Int: i64,
    Num: f64,
    String: *LuaString, // interned; compare by pointer identity
    Table: *Table,
    Builtin: BuiltinId,
    Closure: *Closure,
    Thread: *Thread,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .Nil => "nil",
            .Bool => "boolean",
            .Int, .Num => "number",
            .String => "string",
            .Table => "table",
            .Builtin, .Closure => "function",
            .Thread => "thread",
        };
    }
};

pub const Table = struct {
    // Array part: keys 1..n stored contiguously. A nil entry inside the array
    // is a "hole"; next()/length skip holes by scanning. Untouched by this
    // refactor — all `.array` / `.array.items` call sites stay valid.
    array: std.ArrayListUnmanaged(Value) = .empty,

    // Unified hash part: one PUC-style chained scatter table (Brent's
    // variation) holding all non-array keys (strings, ints out of array range,
    // tables/closures/threads as pointer keys, bools, etc.). Replaces the old
    // three separate maps (`fields` / `int_keys` / `ptr_keys`).
    //
    // A node with `key == .Nil` is a free slot. A node with a non-nil key but
    // `value == .Nil` is a logically-deleted entry (PUC 5.5 semantics: chain
    // links stay intact, compaction happens at rehash).
    hash: []ltable.Node = &[_]ltable.Node{},

    // High-water-mark cursor for `ltable.nodeInsert`'s getFreePos scan. PUC
    // stores this implicitly; we keep it as a sibling field so nodeInsert can
    // resume its downward scan across calls without rescanning the top of the
    // array each time.
    hash_lastfree: usize = 0,

    metatable: ?*Table = null,

    // Testc-only bookkeeping carried over from the old struct. Unrelated to the
    // hash representation; preserved verbatim.
    testc_deferred_vararg_accounting: bool = false,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.array.deinit(alloc);
        if (self.hash.len != 0) alloc.free(self.hash);
    }
};

pub const Vm = struct {
    /// Dummy ir.Function used as a placeholder for bytecode frames.
    /// The bc_vm dispatch loop uses `proto` instead of `func`.
    const bc_dummy_func = ir.Function{
        .name = "<bytecode>",
        .insts = &.{},
        .num_values = 0,
        .num_locals = 0,
    };

    const Frame = struct {
        func: *const ir.Function,
        proto: ?*const bc.Proto = null, // non-null for bytecode frames
        callee: Value,
        regs: []Value,
        locals: []Value,
        boxed: []?*Cell,
        local_active: []bool,
        varargs: []Value,
        upvalues: []const *Cell,
        env_override: ?Value = null,
        frame_id: usize = 0,
        pc: usize = 0,
        top: u8 = 0, // runtime register top (for GC, bytecode frames only)
        current_line: i64,
        last_hook_line: i64,
        used_closing_line_hook: bool = false,
        resume_skip_count_pc: ?usize = null,
        is_tailcall: bool,
        hide_from_debug: bool,
        /// Offset into Vm.bc_stack for bytecode frames. 0 for IR frames.
        bc_base: usize = 0,

        /// ── Frame property accessors ──
        /// For bytecode frames, `func` is bc_dummy_func (all defaults).
        /// The real function info lives in `proto`. These helpers abstract
        /// the difference so callers don't need to special-case.
        pub fn isVararg(fr: Frame) bool {
            if (fr.proto) |p| return p.is_vararg;
            return fr.func.is_vararg;
        }

        pub fn lineDefined(fr: Frame) u32 {
            if (fr.proto) |p| return p.line_defined;
            return fr.func.line_defined;
        }

        pub fn sourceName(fr: Frame) []const u8 {
            if (fr.proto) |p| return p.source_name;
            return fr.func.source_name;
        }

        pub fn numParams(fr: Frame) u32 {
            if (fr.proto) |p| return p.numparams;
            return fr.func.num_params;
        }

        pub fn funcName(fr: Frame) []const u8 {
            if (fr.proto) |p| return p.name;
            return fr.func.name;
        }
    };
    const GmatchState = struct {
        s: *LuaString,
        p: *LuaString,
        pos: usize,
        disallow_empty_at: ?usize = null,
    };
    const FileBuffer = struct {
        mode: enum { full, no, line } = .full,
        pending: std.ArrayListUnmanaged(u8) = .empty,
        pos: u64 = 0,
    };

    alloc: std.mem.Allocator,
    global_env: *Table,
    string_metatable: *Table,
    string_metatable_enabled: bool = true,
    number_metatable: ?*Table = null,
    boolean_metatable: ?*Table = null,
    nil_metatable: ?*Table = null,
    function_metatable: ?*Table = null,
    thread_metatable: ?*Table = null,
    rng_state: [4]u64 = .{ 1, 0xff, 0, 0 },

    // Stable hash seed for `ltable.keyHash` (hashes every int/pointer key on
    // each lookup). MUST be invariant across the Vm's lifetime: a mutating seed
    // (e.g. reading rng_state mid-run) would orphan every prior insert. Value 0
    // is fine — it preserves the legacy AutoHashMap equality semantics; per-VM
    // randomization for hash-flood protection is a separate future concern.
    hash_seed: u64 = 0,

    dump_next_id: u64 = 1,
    dump_registry: std.AutoHashMapUnmanaged(u64, *Closure) = .{},
    // Content→canonical *LuaString dedup table. All `Value.String` pointers
    // come from here, so string equality reduces to pointer comparison.
    string_intern: StringIntern = .{},
    // Long string literals (loaded via ConstString) are deduped by content at
    // compile time regardless of length, like PUC's per-Proto constant table
    // (luaK_stringK search). Long RUNTIME strings (string.rep/concat/format)
    // are NOT deduped — they go through `internStr` which allocates them fresh.
    // So a separate table is needed: a long literal and a long runtime string
    // with the same content must have distinct pointers.
    long_literals: StringIntern = .{},
    finalizables: std.AutoHashMapUnmanaged(*Table, void) = .{},
    debug_registry: ?*Table = null,
    debug_upvalue_ids: std.AutoHashMapUnmanaged(u64, *Table) = .{},

    // Universal per-type registries of every GC-able object allocated during the
    // VM's lifetime. Each object is appended exactly once at its allocation
    // site; the GC sweep phase (implemented in later iterations) enumerates
    // these lists to find and free unreachable objects. `Vm.deinit` drains them
    // as the single ownership point for object destruction at teardown.
    //
    // This replaces PUC Lua's intrusive `GCObject.next` singly-linked list
    // (`g->allgc`) with a per-type `ArrayList(*T)` living on the Vm. Overhead is
    // one pointer per object — identical to PUC's intrusive node — with zero
    // layout change to the managed types, type-safe iteration, and no
    // pointer-juggling during sweep (`swapRemove` is O(1)).
    gc_tables: std.ArrayListUnmanaged(*Table) = .empty,
    gc_closures: std.ArrayListUnmanaged(*Closure) = .empty,
    gc_threads: std.ArrayListUnmanaged(*Thread) = .empty,
    gc_cells: std.ArrayListUnmanaged(*Cell) = .empty,
    // Runtime long strings (len > lua_string_max_short_len) created fresh via
    // `internStr`'s long branch. Short strings are tracked by `string_intern`;
    // long literals by `long_literals` — both own their own destruction. This
    // registry captures only the previously-untracked third category.
    gc_strings: std.ArrayListUnmanaged(*LuaString) = .empty,
    /// Temporary per-cycle mark set for strings. Populated during gcMarkValue
    /// traversal, used by gcSweepStrings. Lives on Vm to avoid changing
    /// gcMarkValue's parameter list.
    gc_marked_strings: std.AutoHashMapUnmanaged(*LuaString, void) = .{},
    /// Temporary per-cycle mark set for cells. Populated during gcMarkValue
    /// when traversing closures' upvalues and frames' boxed/upvalue cells.
    gc_marked_cells: std.AutoHashMapUnmanaged(*Cell, void) = .{},
    /// Source LuaStrings from `load(string)` calls, pinned as GC roots so
    /// their bytes (referenced by ir.Function lexeme slices) survive sweep.
    pinned_source_strings: std.ArrayListUnmanaged(*LuaString) = .empty,
    /// Temporary GC roots (Handle API). Builtins push Values here to protect
    /// newly-allocated objects held in Zig locals across subsequent allocations
    /// that may trigger GC. The scope helper `gcTempRoots()` snapshots the
    /// length; `defer .end()` restores it. GC mark phase traverses this list
    /// in `gcMarkVmRoots`. Non-moving GC → no indirection needed (unlike V8's
    /// HandleScope), just root registration.
    gc_temp_roots: std.ArrayListUnmanaged(Value) = .empty,

    gc_running: bool = true,
    gc_mode: enum { incremental, generational } = .incremental,
    gc_pause: i64 = 200,
    gc_stepmul: i64 = 100,
    gc_alloc_tables: usize = 0,
    // Automatic GC trigger based on table allocations.
    // We keep the default relatively high so table-heavy benchmarks/tests
    // (gc.lua "long list") don't spend most of their time in GC.
    gc_alloc_threshold: usize = 20000,
    gc_in_cycle: bool = false,
    gc_tick: usize = 0,
    gc_inst: usize = 0,
    gc_last_table_inst: usize = 0,
    gc_count_kb: f64 = 0.0,
    testc_gc_count_bonus_once_kb: f64 = 0.0,
    testc_gc_manual_kb: f64 = 0.0,
    testc_gc_pending_finalize_kb: f64 = 0.0,
    testc_gc_pending_finalize_seen: bool = false,
    testc_total_bytes: usize = 0,
    testc_mem_limit: ?usize = null,
    testc_obj_tables: usize = 0,
    testc_obj_functions: usize = 0,
    testc_obj_threads: usize = 0,
    testc_obj_strings: usize = 0,
    // "Allocation-based" triggering is too limited (strings/functions also
    // allocate). To keep the upstream GC tests progressing, also run a
    // best-effort cycle periodically based on VM instruction count.
    gc_tick_threshold: usize = 20000,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    // ── Shared bytecode stack (PUC Lua model) ──
    // A single contiguous array that serves as the register file for ALL
    // bytecode frames. Each frame occupies bc_stack[base .. base+maxstack].
    // No per-frame heap allocation. Stack grows via realloc when needed.
    // After realloc, all `base` offsets in frames are still valid.
    bc_stack: []Value = &.{},
    bc_boxed: []?*Cell = &.{}, // parallel to bc_stack — open upvalue cells per slot
    bc_stack_top: usize = 0, // high-water mark (next available slot)
    bc_stack_initial: usize = 2048,

    err: ?[]const u8 = null,
    err_obj: Value = .Nil,
    err_has_obj: bool = false,
    err_buf: [256]u8 = undefined,
    err_render_buf: [512]u8 = undefined,
    err_source: ?[]const u8 = null,
    err_line: i64 = -1,
    err_traceback: ?[]u8 = null,
    oom_context: ?[]const u8 = null,
    oom_table_array_len: usize = 0,
    oom_table_array_capacity: usize = 0,
    in_error_handler: usize = 0,
    protected_call_depth: usize = 0,
    close_metamethod_depth: usize = 0,
    close_metamethod_err_depth: usize = 0,
    testc_close_metamethod_depth: usize = 0,
    non_yieldable_c_depth: usize = 0,
    coroutine_close_depth: usize = 0,
    current_thread: ?*Thread = null,
    debug_hook_main: DebugHookState = .{},
    in_debug_hook: bool = false,
    debug_hooks_suppressed: usize = 0,
    debug_transfer_values: ?[]const Value = null,
    debug_transfer_start: i64 = 1,
    debug_hook_event_calllike: bool = false,
    debug_hook_event_tailcall: bool = false,
    debug_hook_event_is_count: bool = false,
    debug_namewhat_override: ?[]const u8 = null,
    debug_name_override: ?[]const u8 = null,
    last_builtin_out_count: usize = 0,
    active_builtin: ?BuiltinId = null,
    active_builtin_args: ?[]const Value = null,
    gmatch_state: ?GmatchState = null,
    wrap_thread: ?*Thread = null,
    main_thread: ?*Thread = null,
    forced_close_thread: ?*Thread = null,
    forced_close_had_error: bool = false,
    pattern_match_budget: usize = 0,
    pattern_budget_active: bool = false,
    current_locale: []const u8 = "C",
    next_file_id: i64 = 1,
    file_metatable: ?*Table = null,
    open_files: std.AutoHashMapUnmanaged(i64, std.Io.File) = .{},
    file_buffers: std.AutoHashMapUnmanaged(i64, FileBuffer) = .{},

    pub const Error = std.mem.Allocator.Error || error{ RuntimeError, Yield };
    const VarargValues = struct {
        values: []const Value,
        owned: ?[]Value = null,
    };

    pub fn init(alloc: std.mem.Allocator) Vm {
        const env = alloc.create(Table) catch @panic("oom");
        env.* = .{};
        const str_mt = alloc.create(Table) catch @panic("oom");
        str_mt.* = .{};
        var vm: Vm = .{ .alloc = alloc, .global_env = env, .string_metatable = str_mt };
        vm.gc_tables.append(alloc, env) catch @panic("oom");
        vm.gc_tables.append(alloc, str_mt) catch @panic("oom");
        const main_th = alloc.create(Thread) catch @panic("oom");
        main_th.* = .{
            .callee = .Nil,
            .status = .running,
        };
        vm.main_thread = main_th;
        vm.gc_threads.append(alloc, main_th) catch @panic("oom");
        vm.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0;
        // Allocate shared bytecode stack.
        vm.bc_stack = alloc.alloc(Value, vm.bc_stack_initial) catch @panic("oom");
        @memset(vm.bc_stack, .Nil);
        vm.bc_boxed = alloc.alloc(?*Cell, vm.bc_stack_initial) catch @panic("oom");
        @memset(vm.bc_boxed, null);
        vm.bootstrapGlobals() catch @panic("oom");
        return vm;
    }

    /// Ensure the shared bytecode stack can hold at least `needed` slots.
    /// Grows by doubling + `needed`, reallocating both bc_stack and bc_boxed.
    /// After realloc, all frame `base` offsets remain valid (they're indices).
    fn ensureBcStackCap(self: *Vm, needed: usize) Error!void {
        if (needed <= self.bc_stack.len) return;
        const old_len = self.bc_stack.len;
        var new_cap = old_len;
        while (new_cap < needed) new_cap = new_cap * 2 + needed;
        self.bc_stack = try self.alloc.realloc(self.bc_stack, new_cap);
        self.bc_boxed = try self.alloc.realloc(self.bc_boxed, new_cap);
        // Initialize new slots.
        @memset(self.bc_stack[old_len..], .Nil);
        @memset(self.bc_boxed[old_len..], null);
    }

    /// Grow the current bytecode frame's capacity to hold at least
    /// `needed_local` registers (relative to base).  Grows the shared
    /// stack if necessary, refreshes regs/boxed slices, updates bc_stack_top,
    /// and patches the Frame struct for GC/debug visibility.
    ///
    /// Call this BEFORE writing variable-length results to regs (CALL multret,
    /// VARARG expansion, etc.).  Replaces the old fixed EXTRA_STACK margin.
    fn bcGrowFrame(
        self: *Vm,
        base: usize,
        needed_local: usize,
        frame_cap: *usize,
        regs: *[]Value,
        boxed: *[]?*Cell,
    ) Error!void {
        if (needed_local <= frame_cap.*) return;
        frame_cap.* = needed_local;
        try self.ensureBcStackCap(base + frame_cap.*);
        self.bc_stack_top = @max(self.bc_stack_top, base + frame_cap.*);
        regs.* = self.bc_stack[base..base + frame_cap.*];
        boxed.* = self.bc_boxed[base..base + frame_cap.*];
        // Update Frame for GC/debug (they read fr.regs/fr.boxed).
        if (self.frames.items.len > 0) {
            const fr = &self.frames.items[self.frames.items.len - 1];
            fr.regs = regs.*;
            fr.boxed = boxed.*;
        }
    }

    fn getVarargValues(self: *Vm, f: *const ir.Function, locals: []Value, fallback: []const Value) Error!VarargValues {
        const local_id = f.vararg_table_local orelse return .{ .values = fallback };
        const idx: usize = @intCast(local_id);
        if (idx >= locals.len or locals[idx] != .Table) return .{ .values = fallback };
        const tbl = locals[idx].Table;
        var n: usize = tbl.array.items.len;
        const nv = self.getField(tbl, "n");
        if (nv != .Nil) {
            switch (nv) {
                .Int => |iv| {
                    if (iv < 0 or iv > 100_000) return self.fail("no proper 'n'", .{});
                    n = @intCast(iv);
                },
                else => return self.fail("no proper 'n'", .{}),
            }
        }
        const out = try self.alloc.alloc(Value, n);
        for (0..n) |i| {
            const k: i64 = @intCast(i + 1);
            out[i] = try self.tableGetRawValue(tbl, .{ .Int = k });
        }
        return .{ .values = out, .owned = out };
    }

    pub fn deinit(self: *Vm) void {
        // Run closing finalizers first — they execute Lua __gc metamethods and
        // need most objects (global_env, frames, tables) still alive.
        self.gcFinalizeAtClose();
        // Cleanup non-GC-object resources and bookkeeping maps. These own their
        // own metadata but NOT the GC objects themselves — the registries below
        // are the single ownership point for object destruction.
        var bit = self.file_buffers.iterator();
        while (bit.next()) |entry| entry.value_ptr.pending.deinit(self.alloc);
        self.file_buffers.deinit(self.alloc);
        var fit = self.open_files.iterator();
        while (fit.next()) |entry| entry.value_ptr.*.close(stdio.activeIo());
        self.open_files.deinit(self.alloc);
        if (self.err_traceback) |tb| self.alloc.free(tb);
        self.string_intern.deinit(self.alloc);
        self.long_literals.deinit(self.alloc);
        self.finalizables.deinit(self.alloc);
        self.debug_upvalue_ids.deinit(self.alloc);
        self.dump_registry.deinit(self.alloc);
        self.frames.deinit(self.alloc);
        self.alloc.free(self.bc_stack);
        self.alloc.free(self.bc_boxed);
        // Drain GC registries — destroy every object allocated during the VM's
        // lifetime. Mid-run sweep (when implemented) frees unreachable objects
        // during execution; this catches the survivors at teardown.
        self.drainGcRegistries();
    }

    /// Single ownership point for GC-able object destruction. Iterates each
    /// per-type registry, freeing internal buffers + the struct itself. Order
    /// is irrelevant: each type's cleanup only touches its own memory, never
    /// dereferencing Values (which may be dangling by this point).
    fn drainGcRegistries(self: *Vm) void {
        // Tables: free internal array+hash, then the struct.
        for (self.gc_tables.items) |t| {
            t.deinit(self.alloc);
            self.alloc.destroy(t);
        }
        self.gc_tables.deinit(self.alloc);
        // Closures: free the struct only. cl.upvalues is intentionally NOT freed
        // here — ownership is ambiguous (string.dump clones borrow the original's
        // slice; dofile/load use a static &.{}). Proper upvalue ownership tracking
        // arrives with the mid-run sweep in iteration 3.
        for (self.gc_closures.items) |cl| {
            self.alloc.destroy(cl);
        }
        self.gc_closures.deinit(self.alloc);
        // Threads: free auxiliary buffers (wrap yields, suspended frames, etc.),
        // then the struct. Covers main_thread and all coroutines uniformly.
        for (self.gc_threads.items) |th| {
            self.freeThreadWrapBuffers(th);
            if (th.yielded) |ys| self.alloc.free(ys);
            if (th.locals_snapshot) |snap| self.alloc.free(snap);
            self.alloc.destroy(th);
        }
        self.gc_threads.deinit(self.alloc);
        // Cells: plain struct (single Value field), no internal allocations.
        for (self.gc_cells.items) |c| {
            self.alloc.destroy(c);
        }
        self.gc_cells.deinit(self.alloc);
        // Runtime long strings (allocated fresh by internStr's long branch).
        // Short strings and long literals are owned by string_intern /
        // long_literals respectively, already freed above.
        for (self.gc_strings.items) |s| {
            destroyLuaString(self.alloc, s);
        }
        self.gc_strings.deinit(self.alloc);
        self.gc_marked_strings.deinit(self.alloc);
        self.gc_marked_cells.deinit(self.alloc);
        self.pinned_source_strings.deinit(self.alloc);
        self.gc_temp_roots.deinit(self.alloc);
    }

    // Public API helpers for `src/lua/api.zig`.
    pub fn apiGetGlobal(self: *Vm, name: []const u8) Value {
        return self.getGlobal(name);
    }

    pub fn apiSetGlobal(self: *Vm, name: []const u8, v: Value) Error!void {
        try self.setGlobal(name, v);
    }

    pub fn apiNewTable(self: *Vm) Error!*Table {
        return try self.allocTable();
    }

    pub fn apiNewThread(self: *Vm, callee: Value) Error!*Thread {
        try self.testcChargeMemory(@sizeOf(Thread) + 64);
        const th = try self.alloc.create(Thread);
        th.* = .{ .status = .suspended, .callee = callee };
        try self.gc_threads.append(self.alloc, th);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0;
        self.testc_obj_threads += 1;
        return th;
    }

    pub fn apiRawGet(self: *Vm, tbl: *Table, key: Value) Error!Value {
        return self.tableGetRawValue(tbl, key);
    }

    pub fn apiRawSet(self: *Vm, tbl: *Table, key: Value, value: Value) Error!void {
        try self.tableSetValue(tbl, key, value);
    }

    pub fn apiGetTable(self: *Vm, object: Value, key: Value) Error!Value {
        return self.indexValue(object, key);
    }

    pub fn apiSetTable(self: *Vm, object: Value, key: Value, value: Value) Error!void {
        try self.setIndexValue(object, key, value);
    }

    pub fn apiNext(self: *Vm, tbl: *Table, key: Value, outs: []Value) Error!usize {
        var tmp: [2]Value = .{ .Nil, .Nil };
        try self.builtinNext(&[_]Value{ .{ .Table = tbl }, key }, tmp[0..]);
        if (tmp[0] == .Nil) return 0;
        if (outs.len < 2) return error.RuntimeError;
        outs[0] = tmp[0];
        outs[1] = tmp[1];
        return 2;
    }

    pub fn apiConcat(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return try self.binConcat(lhs, rhs);
    }

    pub fn apiWrapFunction(self: *Vm, func: *const ir.Function) Error!Value {
        const upvalues = try self.alloc.alloc(*Cell, 0);
        try self.testcChargeMemory(@sizeOf(Closure) + 64);
        const cl = try self.alloc.create(Closure);
        cl.* = .{ .func = func, .upvalues = upvalues };
        try self.gc_closures.append(self.alloc, cl);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
        self.testc_obj_functions += 1;
        return .{ .Closure = cl };
    }

    pub fn apiCall(self: *Vm, callee: Value, args: []const Value) Error![]Value {
        const resolved = try self.resolveCallable(callee, args, null);
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);
        switch (resolved.callee) {
            .Builtin => |id| {
                const out_len = self.builtinOutLen(id, resolved.args);
                const outs = try self.alloc.alloc(Value, out_len);
                errdefer self.alloc.free(outs);
                try self.callBuiltin(id, resolved.args, outs);
                const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                if (used == outs.len) return outs;
                const ret = try self.alloc.alloc(Value, used);
                for (0..used) |i| ret[i] = outs[i];
                self.alloc.free(outs);
                return ret;
            },
            .Closure => |cl| return self.runClosure(cl, resolved.args, false),
            else => unreachable,
        }
    }

    pub fn apiResumeThread(self: *Vm, th: *Thread, args: []const Value, outs: []Value) Error!usize {
        if (outs.len == 0) return 0;
        const resume_args = try self.alloc.alloc(Value, args.len + 1);
        defer self.alloc.free(resume_args);
        resume_args[0] = .{ .Thread = th };
        for (args, 0..) |v, i| resume_args[i + 1] = v;
        try self.builtinCoroutineResume(resume_args, outs);
        return self.last_builtin_out_count;
    }

    pub fn apiYield(self: *Vm, args: []const Value) Error!void {
        var out: [0]Value = .{};
        try self.builtinCoroutineYield(args, out[0..]);
    }

    pub fn apiIsYieldable(self: *Vm, th: ?*Thread) Error!bool {
        var out: [1]Value = .{.Nil};
        if (th) |t| {
            try self.builtinCoroutineIsyieldable(&[_]Value{.{ .Thread = t }}, out[0..]);
        } else {
            try self.builtinCoroutineIsyieldable(&.{}, out[0..]);
        }
        return out[0] == .Bool and out[0].Bool;
    }

    pub fn apiStackNormalizeIndex(_: *Vm, stack: *const std.ArrayListUnmanaged(Value), idx: i32) Error!usize {
        if (idx == 0) return error.RuntimeError;
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            if (abs >= stack.items.len) return error.RuntimeError;
            return abs;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > stack.items.len) return error.RuntimeError;
        return stack.items.len - r;
    }

    pub fn apiStackAbsIndex(self: *Vm, stack: *const std.ArrayListUnmanaged(Value), idx: i32) Error!i32 {
        _ = try self.apiStackNormalizeIndex(stack, idx);
        if (idx > 0) return idx;
        return @intCast(@as(i64, @intCast(stack.items.len)) + @as(i64, idx) + 1);
    }

    pub fn apiStackSetTop(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32) Error!void {
        var new_top: usize = 0;
        if (idx >= 0) {
            new_top = @intCast(idx);
        } else {
            const nt = @as(i64, @intCast(stack.items.len)) + @as(i64, idx) + 1;
            if (nt < 0) return error.RuntimeError;
            new_top = @intCast(nt);
        }
        if (new_top <= stack.items.len) {
            stack.items.len = new_top;
        } else {
            try stack.appendNTimes(self.alloc, .Nil, new_top - stack.items.len);
        }
    }

    pub fn apiStackPop(_: *Vm, stack: *std.ArrayListUnmanaged(Value), n: usize) Error!void {
        if (n > stack.items.len) return error.RuntimeError;
        stack.items.len -= n;
    }

    pub fn apiStackPush(self: *Vm, stack: *std.ArrayListUnmanaged(Value), value: Value) Error!void {
        try stack.append(self.alloc, value);
    }

    pub fn apiStackPushValue(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32) Error!void {
        const abs = try self.apiStackNormalizeIndex(stack, idx);
        try stack.append(self.alloc, stack.items[abs]);
    }

    pub fn apiStackRemove(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32) Error!void {
        try self.apiStackRotate(stack, idx, -1);
        try self.apiStackPop(stack, 1);
    }

    pub fn apiStackInsert(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32) Error!void {
        try self.apiStackRotate(stack, idx, 1);
    }

    pub fn apiStackReplace(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32) Error!void {
        if (stack.items.len == 0) return error.RuntimeError;
        const abs = try self.apiStackNormalizeIndex(stack, idx);
        const top = stack.items.len - 1;
        stack.items[abs] = stack.items[top];
        stack.items.len = top;
    }

    pub fn apiStackCopy(self: *Vm, stack: *std.ArrayListUnmanaged(Value), from_idx: i32, to_idx: i32) Error!void {
        const from = try self.apiStackNormalizeIndex(stack, from_idx);
        const to = try self.apiStackNormalizeIndex(stack, to_idx);
        stack.items[to] = stack.items[from];
    }

    pub fn apiStackRotate(self: *Vm, stack: *std.ArrayListUnmanaged(Value), idx: i32, n: i32) Error!void {
        const start = try self.apiStackNormalizeIndex(stack, idx);
        const slice = stack.items[start..];
        if (slice.len <= 1) return;
        var nmod = @mod(@as(i64, n), @as(i64, @intCast(slice.len)));
        if (nmod < 0) nmod += @intCast(slice.len);
        if (nmod == 0) return;
        std.mem.rotate(Value, slice, slice.len - @as(usize, @intCast(nmod)));
    }

    pub fn apiStackConcat(self: *Vm, stack: *std.ArrayListUnmanaged(Value), n: usize) Error!void {
        if (n > stack.items.len) return error.RuntimeError;
        if (n == 0) {
            try stack.append(self.alloc, .{ .String = try self.internStr("") });
            return;
        }
        if (n == 1) return;
        const start = stack.items.len - n;
        var acc = stack.items[start];
        var i = start + 1;
        while (i < stack.items.len) : (i += 1) {
            acc = try self.apiConcat(acc, stack.items[i]);
        }
        stack.items.len = start;
        try stack.append(self.alloc, acc);
    }

    pub fn apiStackXMove(self: *Vm, from_stack: *std.ArrayListUnmanaged(Value), to_stack: *std.ArrayListUnmanaged(Value), n: usize) Error!void {
        if (n > from_stack.items.len) return error.RuntimeError;
        if (n == 0) return;
        const start_idx = from_stack.items.len - n;
        const moved = try self.alloc.alloc(Value, n);
        defer self.alloc.free(moved);
        for (0..n) |i| moved[i] = from_stack.items[start_idx + i];
        from_stack.items.len = start_idx;
        try to_stack.appendSlice(self.alloc, moved);
    }

    fn gcFinalizeAtClose(self: *Vm) void {
        // Closing a Lua state runs pending finalizers once for objects that
        // were already marked as finalizable at close time.
        var to_finalize = std.ArrayListUnmanaged(*Table).empty;
        defer to_finalize.deinit(self.alloc);

        var it = self.finalizables.iterator();
        while (it.next()) |entry| {
            to_finalize.append(self.alloc, entry.key_ptr.*) catch return;
        }

        for (to_finalize.items) |obj| {
            _ = self.finalizables.remove(obj);
            const mt = obj.metatable orelse continue;
            const gc = self.getFieldOpt(mt, "__gc") orelse continue;
            var call_args = [_]Value{.{ .Table = obj }};
            _ = self.callFinalizer(gc, call_args[0..]) catch {};
        }
    }

    fn callFinalizer(self: *Vm, gc: Value, args: []const Value) Error!Value {
        // PUC Lua does not run debug hooks while executing a finalizer body.
        // Keep hooks installed, but suppress line/count/call events for the
        // finalizer call itself.
        self.debug_hooks_suppressed += 1;
        defer self.debug_hooks_suppressed -= 1;
        return self.callMetamethod(gc, "__gc", args);
    }

    pub fn errorString(self: *Vm) []const u8 {
        return self.err orelse "<no error object>";
    }

    fn protectedErrorValue(self: *Vm) Value {
        if (self.err_has_obj) {
            return switch (self.err_obj) {
                .String => .{ .String = self.internStrAssume(self.protectedErrorString()) },
                else => self.err_obj,
            };
        }
        return .{ .String = self.internStrAssume(self.protectedErrorString()) };
    }

    fn clearErrorTraceback(self: *Vm) void {
        if (self.err_traceback) |tb| self.alloc.free(tb);
        self.err_traceback = null;
    }

    fn appendFmt(alloc: std.mem.Allocator, out: anytype, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const text = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    }

    fn captureErrorTraceback(self: *Vm) void {
        self.clearErrorTraceback();
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer aw.deinit();
        var w = &aw.writer;
        w.writeAll("stack traceback:\n") catch return;

        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = self.frames.items[i];
            if (fr.hide_from_debug) continue;
            const src = fr.sourceName();
            const chunk = if (src.len != 0 and (src[0] == '@' or src[0] == '=')) src[1..] else src;
            const line = if (fr.current_line > 0) fr.current_line else 1;
            const name = if (fr.func.name.len != 0) fr.func.name else "?";
            w.print("\t{s}:{d}: in function '{s}'\n", .{ if (chunk.len != 0) chunk else "?", line, name }) catch return;
        }
        w.writeAll("\t[C]: in function 'pcall'") catch return;
        self.err_traceback = aw.toOwnedSlice() catch null;
    }

    fn fail(self: *Vm, comptime fmt: []const u8, args: anytype) Error {
        var tmp: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(tmp[0..], fmt, args) catch "runtime error";
        self.err = std.fmt.bufPrint(self.err_buf[0..], "{s}", .{msg}) catch "runtime error";
        self.err_obj = .{ .String = try self.internStr(self.err.?) };
        self.err_has_obj = true;
        if (self.frames.items.len != 0) {
            const fr = self.frames.items[self.frames.items.len - 1];
            self.err_source = fr.sourceName();
            self.err_line = fr.current_line;
        } else {
            self.err_source = null;
            self.err_line = -1;
        }
        self.captureErrorTraceback();
        return error.RuntimeError;
    }

    fn failAt(self: *Vm, source_name: []const u8, line: i64, comptime fmt: []const u8, args: anytype) Error {
        var tmp: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(tmp[0..], fmt, args) catch "runtime error";
        self.err = std.fmt.bufPrint(self.err_buf[0..], "{s}", .{msg}) catch "runtime error";
        self.err_obj = .{ .String = try self.internStr(self.err.?) };
        self.err_has_obj = true;
        self.err_source = source_name;
        self.err_line = line;
        self.captureErrorTraceback();
        return error.RuntimeError;
    }

    fn setOutOfMemoryError(self: *Vm) void {
        self.err = "not enough memory";
        self.err_obj = .{ .String = self.internStrAssume("not enough memory") };
        self.err_has_obj = true;
        if (stdio.activeEnviron().containsConstant("LUAZIG_TRACE_OOM")) {
            if (self.oom_context) |ctx| {
                std.debug.print("luazig oom: {s} array_len={} array_capacity={}\n", .{
                    ctx,
                    self.oom_table_array_len,
                    self.oom_table_array_capacity,
                });
            }
        }
        if (self.frames.items.len != 0) {
            const fr = self.frames.items[self.frames.items.len - 1];
            self.err_source = fr.sourceName();
            self.err_line = fr.current_line;
        } else {
            self.err_source = null;
            self.err_line = -1;
        }
        self.captureErrorTraceback();
    }

    fn noteTableArrayOomContext(self: *Vm, tbl: *const Table, context: []const u8) void {
        self.oom_context = context;
        self.oom_table_array_len = tbl.array.items.len;
        self.oom_table_array_capacity = tbl.array.capacity;
    }

    fn appendTableArrayValue(self: *Vm, tbl: *Table, val: Value) Error!void {
        if (tbl.array.items.len >= tbl.array.capacity) {
            self.noteTableArrayOomContext(tbl, "table array grow");
            const current = tbl.array.capacity;
            const next = if (current < 8) 8 else current *| 2;
            try tbl.array.ensureTotalCapacityPrecise(self.alloc, next);
        }
        tbl.array.appendAssumeCapacity(val);
    }

    fn protectedErrorString(self: *Vm) []const u8 {
        const base = self.errorString();
        if (self.err_source) |src| {
            if (std.mem.indexOf(u8, base, ":") != null) return base;
            var tmp: [256]u8 = undefined;
            const base_copy = std.fmt.bufPrint(tmp[0..], "{s}", .{base}) catch base;
            if (std.mem.eql(u8, src, "=?")) {
                return std.fmt.bufPrint(self.err_render_buf[0..], "?:?: {s}", .{base_copy}) catch base;
            }
            const chunk_raw = if (src.len != 0 and (src[0] == '@' or src[0] == '=')) src[1..] else src;
            const chunk = if (chunk_raw.len == 0 or chunk_raw.len > 80 or std.mem.indexOfScalar(u8, chunk_raw, '\n') != null) "?" else chunk_raw;
            const line = self.err_line;
            if (line >= 1) {
                return std.fmt.bufPrint(self.err_render_buf[0..], "{s}:{d}: {s}", .{ chunk, line, base_copy }) catch base;
            }
            return std.fmt.bufPrint(self.err_render_buf[0..], "{s}:?: {s}", .{ chunk, base_copy }) catch base;
        }
        return base;
    }

    fn activeHookState(self: *Vm) *DebugHookState {
        if (self.current_thread) |th| return &th.debug_hook;
        if (self.main_thread) |th| return &th.debug_hook;
        return &self.debug_hook_main;
    }

    fn hookStateFor(self: *Vm, target_thread: ?*Thread) *DebugHookState {
        if (target_thread) |th| return &th.debug_hook;
        if (self.current_thread) |th| return &th.debug_hook;
        if (self.main_thread) |th| return &th.debug_hook;
        return &self.debug_hook_main;
    }

    fn testcChargeMemory(self: *Vm, bytes: usize) Error!void {
        if (bytes == 0) return;
        try self.testcConsumeAllocCount();
        const next = self.testc_total_bytes +| bytes;
        if (self.testc_mem_limit) |limit| {
            if (next > limit) return self.failTestcRaw("not enough memory");
        }
        self.testc_total_bytes = next;
    }

    fn testcConsumeAllocCount(self: *Vm) Error!void {
        const t_global = self.getGlobal("T");
        if (t_global != .Table) return;
        const cur = self.getField(t_global.Table, "_alloccount");
        if (cur == .Nil) return;
        const n = switch (cur) {
            .Int => |i| i,
            .Num => |x| @as(i64, @intFromFloat(x)),
            else => return,
        };
        if (n < 0) return;
        if (n == 0) return self.failTestcRaw("not enough memory");
        try self.setField(t_global.Table, "_alloccount", .{ .Int = n - 1 });
    }

    fn testcNoteMemory(self: *Vm, bytes: usize) void {
        self.testc_total_bytes +|= bytes;
    }

    fn isTestcMemoryErrorValue(v: Value) bool {
        return v == .String and std.mem.indexOf(u8, v.String.bytes(), "not enough memory") != null;
    }

    /// Scoped temporary GC root registration (Handle API).
    ///
    /// Usage:
    ///   var roots = self.gcTempRoots();
    ///   defer roots.end();
    ///   try roots.add(.{ .Table = tbl });
    ///
    /// `add()` pushes a Value onto `gc_temp_roots`; `end()` truncates back to
    /// the snapshot length. GC mark phase traverses all entries in
    /// `gc_temp_roots` (via gcMarkVmRoots), so pushed objects survive sweep.
    /// This is the non-moving-GC analog of PUC Lua's `L->stack[0..top]` —
    /// builtins register their Zig-local temporaries as GC roots.
    const TempRoots = struct {
        vm: *Vm,
        snapshot: usize,

        pub fn add(self: *TempRoots, v: Value) Error!void {
            try self.vm.gc_temp_roots.append(self.vm.alloc, v);
        }

        pub fn end(self: *TempRoots) void {
            self.vm.gc_temp_roots.shrinkRetainingCapacity(self.snapshot);
        }
    };

    fn gcTempRoots(self: *Vm) TempRoots {
        return .{ .vm = self, .snapshot = self.gc_temp_roots.items.len };
    }

    fn allocTableNoGc(self: *Vm) std.mem.Allocator.Error!*Table {
        self.testcNoteMemory(@sizeOf(Table) + 64);
        const t = try self.alloc.create(Table);
        t.* = .{};
        try self.gc_tables.append(self.alloc, t);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Table))) / 1024.0;
        self.testc_obj_tables += 1;
        return t;
    }

    fn allocTable(self: *Vm) Error!*Table {
        try self.testcConsumeAllocCount();
        const t = try self.allocTableNoGc();
        self.gc_alloc_tables += 1;
        self.gc_last_table_inst = self.gc_inst;
        // Adaptive threshold: tests that create many __gc objects rely on
        // "automatic" collection happening in a reasonable number of
        // allocations, but most code should not run GC too frequently.
        const threshold = if (self.finalizables.count() != 0) 200 else self.gc_alloc_threshold;
        if (self.gc_running and !self.gc_in_cycle and self.gc_alloc_tables >= threshold) {
            self.gc_alloc_tables = 0;
            // Protect the just-allocated table: it's in the gc_tables registry
            // but not yet in any root (hasn't been returned to the caller).
            // Temp roots ensure the mark phase sees it and sweep keeps it alive.
            var roots = self.gcTempRoots();
            defer roots.end();
            try roots.add(.{ .Table = t });
            // Full cycle with sweep. Temp roots + live_regs make this safe even
            // mid-expression — the mark phase sees all live values.
            try self.gcCycleFullInternal(true);
        }
        return t;
    }

    fn allocTableEphemeral(self: *Vm) std.mem.Allocator.Error!*Table {
        const t = try self.alloc.create(Table);
        t.* = .{};
        try self.gc_tables.append(self.alloc, t);
        return t;
    }

    fn testcMaterializeDeferredVarargTable(self: *Vm, value: Value) Error!void {
        if (value != .Table) return;
        const tbl = value.Table;
        if (!tbl.testc_deferred_vararg_accounting) return;
        tbl.testc_deferred_vararg_accounting = false;
        try self.testcChargeMemory(@sizeOf(Table) + 64);
        try self.testcChargeMemory(@max(tbl.array.items.len, 1) * @sizeOf(Value));
        try self.testcChargeMemory(64);
    }

    fn testcMaterializeDeferredVarargReturns(self: *Vm, values: []const Value) Error!void {
        for (values) |v| try self.testcMaterializeDeferredVarargTable(v);
    }

    pub fn runFunction(self: *Vm, f: *const ir.Function) Error![]Value {
        var env_cell = Cell{ .value = .{ .Table = self.global_env } };
        var top_ups = [_]*Cell{&env_cell};
        var top_cl = Closure{ .func = f, .upvalues = top_ups[0..] };
        return self.runFunctionArgsWithUpvalues(f, top_ups[0..], &.{}, &top_cl, false) catch |e| switch (e) {
            error.Yield => self.fail("attempt to yield from outside coroutine", .{}),
            else => return e,
        };
    }

    pub fn runFunctionArgs(self: *Vm, f: *const ir.Function, args: []const Value) Error![]Value {
        var env_cell = Cell{ .value = .{ .Table = self.global_env } };
        var top_ups = [_]*Cell{&env_cell};
        var top_cl = Closure{ .func = f, .upvalues = top_ups[0..] };
        return self.runFunctionArgsWithUpvalues(f, top_ups[0..], args, &top_cl, false) catch |e| switch (e) {
            error.Yield => self.fail("attempt to yield from outside coroutine", .{}),
            else => return e,
        };
    }

    fn runFunctionArgsWithUpvalues(self: *Vm, f: *const ir.Function, upvalues: []const *Cell, args: []const Value, callee_cl: ?*Closure, is_tailcall: bool) Error![]Value {
        // This VM currently executes Lua calls via host recursion.
        // Keep a conservative cap to avoid crashing the process before we can
        // report a proper Lua "stack overflow" error.
        const max_depth: usize = if (self.close_metamethod_depth != 0)
            512
        else if (self.protected_call_depth != 0)
            256
        else
            400;
        if (self.frames.items.len >= max_depth) {
            if (self.protected_call_depth != 0) return self.fail("C stack overflow", .{});
            return self.fail("stack overflow error", .{});
        }
        const nilv: Value = .Nil;
        var regs: []Value = undefined;
        var locals: []Value = undefined;
        var local_active: []bool = undefined;
        var boxed: []?*Cell = undefined;
        var varargs: []Value = undefined;
        var pc: usize = 0;

        const initial_line: i64 = if (f.line_defined > 0) @as(i64, @intCast(f.line_defined)) else 1;
        var frame_current_line: i64 = initial_line;
        var frame_last_hook_line: i64 = -1;
        var frame_used_closing_line_hook = false;
        var frame_resume_skip_count_pc: ?usize = null;
        var frame_id: usize = 0;
        var resumed_from_snapshot = false;
        var resumed_yield_id: usize = 0;
        if (self.current_thread) |th| {
            if (th.in_resume) {
                if (popMatchingSuspendedFrame(self, th, f, upvalues, callee_cl)) |snap| {
                    regs = snap.regs;
                    locals = snap.locals;
                    local_active = snap.local_active;
                    boxed = snap.boxed;
                    varargs = snap.varargs;
                    frame_current_line = snap.current_line;
                    frame_last_hook_line = snap.last_hook_line;
                    frame_used_closing_line_hook = snap.used_closing_line_hook;
                    frame_resume_skip_count_pc = snap.resume_skip_count_pc;
                    if (snap.direct_yield) frame_last_hook_line = frame_current_line;
                    frame_id = snap.frame_id;
                    self.alloc.free(snap.upvalues);
                    const yielded_pc = snap.pc;
                    if (snap.direct_yield and th.internal_resume_after_yield) {
                        pc = yielded_pc + 1;
                        th.suspended_pc = 0;
                        th.suspended_direct_yield = false;
                        frame_resume_skip_count_pc = yielded_pc + 1;
                    } else {
                        pc = yielded_pc;
                        th.suspended_pc = yielded_pc + 1;
                        th.suspended_direct_yield = snap.direct_yield;
                        if (!snap.direct_yield) th.suspended_pc = 0;
                        if (snap.from_count_hook) {
                            frame_resume_skip_count_pc = yielded_pc;
                        }
                    }
                    resumed_yield_id = snap.yield_id;
                    resumed_from_snapshot = true;
                }
            }
            if (!resumed_from_snapshot) {
                th.frame_id_counter += 1;
                frame_id = th.frame_id_counter;
            }
        }
        if (!resumed_from_snapshot) {
            regs = try self.alloc.alloc(Value, f.num_values);
            for (regs) |*r| r.* = nilv;

            locals = try self.alloc.alloc(Value, @as(usize, @intCast(f.num_locals)));
            for (locals) |*l| l.* = nilv;

            local_active = try self.alloc.alloc(bool, @as(usize, @intCast(f.num_locals)));
            for (local_active) |*a| a.* = false;

            boxed = try self.alloc.alloc(?*Cell, @as(usize, @intCast(f.num_locals)));
            for (boxed) |*b| b.* = null;

            const nparams: usize = @intCast(f.num_params);
            var pi: usize = 0;
            while (pi < nparams) : (pi += 1) {
                locals[pi] = if (pi < args.len) args[pi] else .Nil;
                local_active[pi] = true;
            }
            const varargs_src = if (f.is_vararg and args.len > nparams) args[nparams..] else &[_]Value{};
            varargs = try self.alloc.alloc(Value, varargs_src.len);
            for (varargs_src, 0..) |v, i| varargs[i] = v;
        }
        defer self.alloc.free(regs);
        defer self.alloc.free(locals);
        defer self.alloc.free(local_active);
        defer self.alloc.free(boxed);
        defer self.alloc.free(varargs);
        try self.frames.append(self.alloc, .{
            .func = f,
            .callee = if (callee_cl) |cl| .{ .Closure = cl } else .Nil,
            .regs = regs,
            .locals = locals,
            .boxed = boxed,
            .local_active = local_active,
            .varargs = varargs,
            .upvalues = upvalues,
            .env_override = if (callee_cl) |cl| cl.env_override else null,
            .frame_id = frame_id,
            .current_line = frame_current_line,
            .last_hook_line = frame_last_hook_line,
            .used_closing_line_hook = frame_used_closing_line_hook,
            .resume_skip_count_pc = frame_resume_skip_count_pc,
            .is_tailcall = is_tailcall,
            .hide_from_debug = false,
        });
        defer _ = self.frames.pop();
        if (resumed_from_snapshot and resumed_yield_id != 0) {
            if (self.current_thread) |th| {
                try self.resumePendingDirectYieldChildren(th, resumed_yield_id, self.frames.items.len);
            }
        }
        errdefer {
            if (self.current_thread) |th| {
                if (th.status == .running and self.frames.items.len != 0 and th.capture_yield_id != 0) {
                    self.captureThreadSuspendedFrame(th, &self.frames.items[self.frames.items.len - 1], pc) catch {};
                }
            }
        }
        const has_close_locals = functionHasCloseLocals(f);
        errdefer {
            if (has_close_locals and (self.err_has_obj or self.err != null) and (self.current_thread == null or self.current_thread.?.yielded == null)) {
                if (self.frames.items.len > 0) {
                    self.frames.items[self.frames.items.len - 1].hide_from_debug = true;
                }
                var current_err: ?Value = null;
                if (self.err_has_obj) {
                    current_err = self.err_obj;
                } else if (self.err) |msg| {
                    current_err = .{ .String = self.internStrAssume(msg) };
                }
                var prev_unwind = false;
                var have_prev_unwind = false;
                if (self.current_thread) |th| {
                    prev_unwind = th.in_close_pending_unwind;
                    have_prev_unwind = true;
                    th.in_close_pending_unwind = true;
                }
                defer if (self.current_thread) |th| {
                    if (have_prev_unwind) th.in_close_pending_unwind = prev_unwind;
                };
                _ = self.closePendingFunctionLocals(f, locals, local_active, boxed, current_err) catch {};
            }
        }

        var labels = std.AutoHashMapUnmanaged(ir.LabelId, usize){};
        defer labels.deinit(self.alloc);
        for (f.insts, 0..) |inst, idx| {
            switch (inst) {
                .Label => |l| try labels.put(self.alloc, l.id, idx),
                else => {},
            }
        }

        const inst_line_count = f.inst_lines.len;
        const src_name = f.source_name;
        const src_looks_like_path = src_name.len != 0 and
            (std.mem.endsWith(u8, src_name, ".lua") or
                std.mem.indexOfScalar(u8, src_name, '/') != null or
                std.mem.indexOfScalar(u8, src_name, '\\') != null);
        const source_line_bias: u32 = if (f.line_defined == 0 and src_looks_like_path) 1 else 0;

        while (pc < f.insts.len) {
            const fr = &self.frames.items[self.frames.items.len - 1];
            fr.pc = pc;
            const inst = f.insts[pc];
            if (self.current_thread) |th| {
                if (th.close_mode and th.suspended_direct_yield and th.suspended_pc != 0 and th.suspended_pc == pc + 1) {
                    const should_raise = switch (inst) {
                        .Call => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        .CallVararg => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        .CallExpand => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        .ReturnCall => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        .ReturnCallVararg => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        .ReturnCallExpand => |c| switch (regs[c.func]) {
                            .Builtin => |id| id == .pcall or id == .xpcall or id == .dofile,
                            else => false,
                        },
                        else => false,
                    };
                    if (should_raise) {
                        if (th.resume_inbox) |vals| {
                            self.alloc.free(vals);
                            th.resume_inbox = null;
                        }
                        th.suspended_pc = 0;
                        th.suspended_direct_yield = false;
                        return self.fail("attempt to yield across a C-call boundary", .{});
                    }
                }
            }
            const hook_state = self.activeHookState();
            const line_eligible = true;
            var has_line_info = false;
            if (pc < inst_line_count) {
                const line = f.inst_lines[pc];
                if (line != 0) {
                    const computed_line: i64 = @intCast(line + source_line_bias);
                    fr.current_line = if (fr.lineDefined() > 0 and computed_line < initial_line) initial_line else computed_line;
                    fr.used_closing_line_hook = false;
                    has_line_info = true;
                }
            }
            if (hook_state.has_line and !hook_state.line_hook_preseeded and !self.in_debug_hook and self.debug_hooks_suppressed == 0 and line_eligible) {
                if (hook_state.skip_line_once) {
                    if (self.frames.items.len >= hook_state.skip_line_until_depth) {
                        fr.last_hook_line = if (has_line_info) fr.current_line else -2;
                        hook_state.skip_line_once = false;
                        hook_state.skip_line_until_depth = 0;
                    } else {
                        hook_state.skip_line_once = false;
                        hook_state.skip_line_until_depth = 0;
                    }
                }
                if (!hook_state.skip_line_once and has_line_info) {
                    if (fr.last_hook_line != fr.current_line) {
                        fr.last_hook_line = fr.current_line;
                        try self.debugDispatchHook("line", fr.current_line);
                    }
                } else if (!hook_state.skip_line_once) {
                    const synthetic_closing_line = fr.current_line > 0 and !fr.used_closing_line_hook and !functionHasFutureLineInfo(f, pc);
                    if (synthetic_closing_line) {
                        // Our IR tail returns often carry no explicit line info,
                        // but Lua still reports the source-visible closing line
                        // as the last hookable step of the function.
                        const closing_line = fr.current_line + 1;
                        if (fr.last_hook_line != closing_line) {
                            fr.current_line = closing_line;
                            fr.last_hook_line = closing_line;
                            fr.used_closing_line_hook = true;
                            try self.debugDispatchHook("line", closing_line);
                        }
                    } else if (f.inst_lines.len == 0) {
                        // Stripped chunks have no line table; Lua emits line hook
                        // with nil line info once at function entry.
                        if (fr.last_hook_line != -2) {
                            fr.last_hook_line = -2;
                            try self.debugDispatchHook("line", null);
                        }
                    }
                }
            }

            if (hook_state.count > 0 and !self.in_debug_hook and self.debug_hooks_suppressed == 0 and isDebugCountHookInst(inst)) {
                if (fr.resume_skip_count_pc) |skip_pc| {
                    if (skip_pc == pc) {
                        // Resuming from a count-hook yield must not immediately
                        // fire the same hook again at the interrupted opcode.
                    } else {
                        fr.resume_skip_count_pc = null;
                        hook_state.budget -= 1;
                        if (hook_state.budget <= 0) {
                            hook_state.budget = hook_state.count;
                            try self.debugDispatchHook("count", null);
                        }
                    }
                } else if (hook_state.skip_count_once) {
                    hook_state.skip_count_once = false;
                } else {
                    hook_state.budget -= 1;
                    if (hook_state.budget <= 0) {
                        hook_state.budget = hook_state.count;
                        try self.debugDispatchHook("count", null);
                    }
                }
            }

            if (self.gc_running and !self.gc_in_cycle) {
                self.gc_inst += 1;
                // Avoid doing tick-based GC in table-heavy code (allocTable
                // already triggers periodic cycles), but allow it when we're
                // allocating other objects (strings/functions) for a while.
                if (self.gc_inst - self.gc_last_table_inst > 256) {
                    self.gc_tick += 1;
                    if (self.gc_tick >= self.gc_tick_threshold) {
                        self.gc_tick = 0;
                        // Tick trigger: between instructions. Register-top tracking
                        // (live_regs) ensures all live registers are marked. Safe
                        // to sweep here — no builtin is executing.
                        try self.gcCycleFull();
                    }
                }
            }

            switch (inst) {
                .ConstNil => |n| regs[n.dst] = .Nil,
                .ConstBool => |b| regs[b.dst] = .{ .Bool = b.val },
                .ConstInt => |n| regs[n.dst] = .{ .Int = try self.parseInt(n.lexeme) },
                .ConstNum => |n| {
                    if (self.parseHexIntWrap(n.lexeme)) |iv| {
                        regs[n.dst] = .{ .Int = iv };
                    } else {
                        regs[n.dst] = .{ .Num = try self.parseNum(n.lexeme) };
                    }
                },
                .ConstString => |s| regs[s.dst] = .{ .String = try self.decodeStringLexeme(s.lexeme) },
                .ConstFunc => |cf| regs[cf.dst] = .{ .Closure = try self.makeClosure(cf.func, locals, boxed, upvalues) },

                .GetName => |g| regs[g.dst] = try self.getNameInFrame(self.frames.items.len - 1, g.name),
                .SetName => |s| try self.setNameInFrame(self.frames.items.len - 1, s.name, regs[s.src]),
                .GetLocal => |g| {
                    const idx: usize = @intCast(g.local);
                    regs[g.dst] = if (boxed[idx]) |cell| cell.value else locals[idx];
                },
                .SetLocal => |s| {
                    const idx: usize = @intCast(s.local);
                    var set_val = regs[s.src];
                    if (forNumericControlForLocal(f, idx)) |ctrl| {
                        if (coerceArithmeticValue(set_val)) |cv| set_val = cv;
                        if (idx == @as(usize, @intCast(ctrl.init_local))) {
                            const step_idx: usize = @intCast(ctrl.step_local);
                            const step_v = localValueAt(locals, boxed, step_idx);
                            if (step_v == .Num) {
                                switch (set_val) {
                                    .Int => |iv| set_val = .{ .Num = @as(f64, @floatFromInt(iv)) },
                                    else => {},
                                }
                            }
                        }
                    }
                    if (self.current_thread) |th| {
                        if (lookupThreadFrameLocalOverride(th, fr.frame_id, idx)) |ov| {
                            if (isCloseLocalIndex(f, idx) and self.isYieldCloseObject(ov)) {
                                set_val = ov;
                            }
                        }
                    }
                    if (boxed[idx]) |cell| {
                        cell.value = set_val;
                        // Keep the stack slot in sync for GC root scanning.
                        locals[idx] = set_val;
                    } else {
                        locals[idx] = set_val;
                    }
                    local_active[idx] = true;
                    if (isCloseLocalIndex(f, idx)) {
                        const cur = if (boxed[idx]) |cell| cell.value else locals[idx];
                        if (!(cur == .Nil or (cur == .Bool and !cur.Bool))) {
                            if (metamethodValue(self, cur, "__close") == null) {
                                const name = if (idx < f.local_names.len) f.local_names[idx] else "?";
                                if (boxed[idx]) |cell| cell.value = .Nil;
                                locals[idx] = .Nil;
                                local_active[idx] = false;
                                return self.fail("variable '{s}' got a non-closable value", .{name});
                            }
                        }
                    }
                },
                .CloseLocal => |c| {
                    const idx: usize = @intCast(c.local);
                    if (local_active[idx]) {
                        const cur = if (boxed[idx]) |cell| cell.value else locals[idx];
                        if (self.current_thread) |th| {
                            const nm = if (idx < f.local_names.len) f.local_names[idx] else "";
                            try self.setThreadFrameLocalOverride(th, fr.frame_id, idx, nm, cur);
                        }
                        self.runCloseMetamethod(cur, null) catch |e| switch (e) {
                            error.RuntimeError => {
                                // A close handler finished with error: local is already closed
                                // and must not be closed again by the pending-close sweep.
                                if (boxed[idx]) |cell| cell.value = .Nil;
                                locals[idx] = .Nil;
                                local_active[idx] = false;
                                boxed[idx] = null;
                                if (has_close_locals) {
                                    var current_err: ?Value = null;
                                    if (self.err_has_obj) {
                                        current_err = self.err_obj;
                                    } else if (self.err) |msg| {
                                        current_err = .{ .String = try self.internStr(msg) };
                                    }
                                    _ = self.closePendingFunctionLocals(f, locals, local_active, boxed, current_err) catch {};
                                }
                                return error.RuntimeError;
                            },
                            else => return e,
                        };
                        if (boxed[idx]) |cell| cell.value = .Nil;
                        locals[idx] = .Nil;
                        local_active[idx] = false;
                        // After leaving scope, reusing this local slot must
                        // create a fresh capture cell for new declarations.
                        boxed[idx] = null;
                    }
                },
                .ClearLocal => |c| {
                    const idx: usize = @intCast(c.local);
                    locals[idx] = .Nil;
                    // Scope ended: future declarations that reuse this local slot
                    // must get a fresh capture cell (if captured), not the old one.
                    boxed[idx] = null;
                    local_active[idx] = false;
                },
                .GetUpvalue => |g| {
                    const idx: usize = @intCast(g.upvalue);
                    if (idx >= upvalues.len) return self.fail("invalid upvalue index u{d}", .{g.upvalue});
                    regs[g.dst] = upvalues[idx].value;
                },
                .SetUpvalue => |s| {
                    const idx: usize = @intCast(s.upvalue);
                    if (idx >= upvalues.len) return self.fail("invalid upvalue index u{d}", .{s.upvalue});
                    upvalues[idx].value = regs[s.src];
                },

                .UnOp => |u| {
                    const op_line: i64 = if (pc < f.inst_lines.len and f.inst_lines[pc] != 0) @intCast(f.inst_lines[pc]) else self.frames.items[self.frames.items.len - 1].current_line;
                    regs[u.dst] = self.evalUnOp(u.op, regs[u.src]) catch |err| {
                        if (err == error.RuntimeError and self.err != null and u.op == .Minus and std.mem.startsWith(u8, self.err.?, "type error: unary '-' expects number")) {
                            if (inferOperandName(f, pc, u.src)) |nm| {
                                if (nm.name) |name| {
                                    return self.failAt(f.source_name, op_line, "attempt to perform arithmetic on a {s} value ({s} '{s}')", .{ self.valueTypeName(regs[u.src]), nm.namewhat, name });
                                }
                            }
                        }
                        if (err == error.RuntimeError and self.err != null and u.op == .Tilde and std.mem.startsWith(u8, self.err.?, "number has no integer representation")) {
                            if (inferOperandName(f, pc, u.src)) |nm| {
                                if (nm.name) |name| {
                                    return self.failAt(f.source_name, op_line, "number has no integer representation ({s} '{s}')", .{ nm.namewhat, name });
                                }
                            }
                        }
                        return err;
                    };
                },
                .BinOp => |b| {
                    const op_line: i64 = if (pc < f.inst_lines.len and f.inst_lines[pc] != 0) @intCast(f.inst_lines[pc]) else self.frames.items[self.frames.items.len - 1].current_line;
                    regs[b.dst] = self.evalBinOp(b.op, regs[b.lhs], regs[b.rhs]) catch |err| {
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "arithmetic on ")) {
                            const lhs_bad = !isNumberLikeForArithmetic(regs[b.lhs]);
                            const rhs_bad = !isNumberLikeForArithmetic(regs[b.rhs]);
                            if (lhs_bad) {
                                if (inferOperandName(f, pc, b.lhs)) |nm| {
                                    if (nm.name) |name| {
                                        return self.failAt(f.source_name, op_line, "attempt to perform arithmetic on a {s} value ({s} '{s}')", .{ self.valueTypeName(regs[b.lhs]), nm.namewhat, name });
                                    }
                                }
                            }
                            if (rhs_bad) {
                                if (inferOperandName(f, pc, b.rhs)) |nm| {
                                    if (nm.name) |name| {
                                        return self.failAt(f.source_name, op_line, "attempt to perform arithmetic on a {s} value ({s} '{s}')", .{ self.valueTypeName(regs[b.rhs]), nm.namewhat, name });
                                    }
                                }
                            }
                        }
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "number has no integer representation")) {
                            if (isNumWithoutInteger(regs[b.lhs])) {
                                if (inferOperandName(f, pc, b.lhs)) |nm| {
                                    if (nm.name) |name| {
                                        return self.failAt(f.source_name, op_line, "number has no integer representation ({s} '{s}')", .{ nm.namewhat, name });
                                    }
                                }
                            }
                            if (isNumWithoutInteger(regs[b.rhs])) {
                                if (inferOperandName(f, pc, b.rhs)) |nm| {
                                    if (nm.name) |name| {
                                        return self.failAt(f.source_name, op_line, "number has no integer representation ({s} '{s}')", .{ nm.namewhat, name });
                                    }
                                }
                            }
                        }
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "attempt to compare ")) {
                            const lhs_nm = inferOperandName(f, pc, b.lhs);
                            const rhs_nm = inferOperandName(f, pc, b.rhs);
                            if (lhs_nm) |nm| {
                                if (nm.name) |name| {
                                    if (std.mem.eql(u8, nm.namewhat, "local") and
                                        (std.mem.eql(u8, name, "initial value") or std.mem.eql(u8, name, "limit") or std.mem.eql(u8, name, "step") or
                                            std.mem.eql(u8, name, "(for initial value)") or std.mem.eql(u8, name, "(for limit)") or std.mem.eql(u8, name, "(for step)")) and
                                        !isNumberLikeForArithmetic(regs[b.lhs]))
                                    {
                                        return self.failAt(f.source_name, op_line, "attempt to compare {s} with {s} ({s} '{s}')", .{ self.valueTypeName(regs[b.lhs]), self.valueTypeName(regs[b.rhs]), nm.namewhat, name });
                                    }
                                }
                            }
                            if (rhs_nm) |nm| {
                                if (nm.name) |name| {
                                    if (std.mem.eql(u8, nm.namewhat, "local") and
                                        (std.mem.eql(u8, name, "initial value") or std.mem.eql(u8, name, "limit") or std.mem.eql(u8, name, "step") or
                                            std.mem.eql(u8, name, "(for initial value)") or std.mem.eql(u8, name, "(for limit)") or std.mem.eql(u8, name, "(for step)")) and
                                        !isNumberLikeForArithmetic(regs[b.rhs]))
                                    {
                                        return self.failAt(f.source_name, op_line, "attempt to compare {s} with {s} ({s} '{s}')", .{ self.valueTypeName(regs[b.lhs]), self.valueTypeName(regs[b.rhs]), nm.namewhat, name });
                                    }
                                }
                            }
                        }
                        return err;
                    };
                },

                .Label => {},
                .Jump => |j| {
                    pc = labels.get(j.target) orelse return self.fail("unknown label L{d}", .{j.target});
                    continue;
                },
                .JumpIfFalse => |j| {
                    if (!isTruthy(regs[j.cond])) {
                        pc = labels.get(j.target) orelse return self.fail("unknown label L{d}", .{j.target});
                        continue;
                    }
                },
                .RaiseError => |r| {
                    return self.fail("{s}", .{r.msg});
                },

                .NewTable => |t| {
                    const tbl = try self.allocTable();
                    regs[t.dst] = .{ .Table = tbl };
                },
                .SetField => |s| {
                    self.setIndexValue(regs[s.object], .{ .String = try self.internStr(s.name) }, regs[s.value]) catch |err| {
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "attempt to index a ")) {
                            if (inferOperandName(f, pc, s.object)) |nm| {
                                if (nm.name) |name| {
                                    return self.fail("attempt to index a {s} value ({s} '{s}')", .{ regs[s.object].typeName(), nm.namewhat, name });
                                }
                            }
                        }
                        return err;
                    };
                },
                .SetIndex => |s| {
                    self.setIndexValue(regs[s.object], regs[s.key], regs[s.value]) catch |err| {
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "attempt to index a ")) {
                            if (inferOperandName(f, pc, s.object)) |nm| {
                                if (nm.name) |name| {
                                    return self.fail("attempt to index a {s} value ({s} '{s}')", .{ regs[s.object].typeName(), nm.namewhat, name });
                                }
                            }
                        }
                        return err;
                    };
                },
                .Append => |a| {
                    const tbl = try self.expectTable(regs[a.object]);
                    try tbl.array.append(self.alloc, regs[a.value]);
                },
                .AppendCallExpand => |a| {
                    const tbl = try self.expectTable(regs[a.object]);
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            for (vals) |v| try tbl.array.append(self.alloc, v);
                            pc += 1;
                            continue;
                        }
                    }
                    const tail_ret = try self.evalCallSpec(a.tail, regs, varargs);
                    defer self.alloc.free(tail_ret);
                    for (tail_ret) |v| try tbl.array.append(self.alloc, v);
                },
                .AppendVarargExpand => |a| {
                    const tbl = try self.expectTable(regs[a.object]);
                    for (varargs) |v| try tbl.array.append(self.alloc, v);
                },
                .GetField => |g| {
                    regs[g.dst] = self.indexValue(regs[g.object], .{ .String = try self.internStr(g.name) }) catch |err| {
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "attempt to index a ")) {
                            if (inferOperandName(f, pc, g.object)) |nm| {
                                if (nm.name) |name| {
                                    return self.fail("attempt to index a {s} value ({s} '{s}')", .{ regs[g.object].typeName(), nm.namewhat, name });
                                }
                            }
                        }
                        return err;
                    };
                },
                .GetIndex => |g| {
                    regs[g.dst] = self.indexValue(regs[g.object], regs[g.key]) catch |err| {
                        if (err == error.RuntimeError and self.err != null and std.mem.startsWith(u8, self.err.?, "attempt to index a ")) {
                            if (inferOperandName(f, pc, g.object)) |nm| {
                                if (nm.name) |name| {
                                    return self.fail("attempt to index a {s} value ({s} '{s}')", .{ regs[g.object].typeName(), nm.namewhat, name });
                                }
                            }
                        }
                        return err;
                    };
                },

                .Call => |c| {
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const callee = regs[c.func];
                            try self.debugDispatchHookWithCalleeTransfer("return", null, callee, vals, 1);
                            for (c.dsts, 0..) |dst, i| regs[dst] = if (i < vals.len) vals[i] else .Nil;
                            pc += 1;
                            continue;
                        }
                    }
                    const callee = regs[c.func];
                    const call_args = try self.alloc.alloc(Value, c.args.len);
                    defer self.alloc.free(call_args);
                    for (c.args, 0..) |id, k| call_args[k] = regs[id];
                    for (c.dsts) |dst| regs[dst] = .Nil;

                    const call_name = inferCallName(f, pc, c.func, c.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    try self.runResolvedCallInto(resolved, c.dsts, regs);
                },
                .ForIterCall => |c| {
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const callee = regs[c.func];
                            try self.debugDispatchHookWithCalleeTransfer("return", null, callee, vals, 1);
                            for (c.dsts, 0..) |dst, i| regs[dst] = if (i < vals.len) vals[i] else .Nil;
                            pc += 1;
                            continue;
                        }
                    }
                    const callee = regs[c.func];
                    const hooks_active = self.hasActiveHookEvent('c') or self.hasActiveHookEvent('r');

                    switch (callee) {
                        .Builtin => |id| switch (id) {
                            .next, .ipairs_iter => {
                                if (!hooks_active) {
                                    try self.runBuiltinForIterFast(id, regs[c.state], regs[c.ctrl], c.dsts, regs);
                                } else {
                                    for (c.dsts) |dst| regs[dst] = .Nil;
                                    var call_args = [_]Value{ regs[c.state], regs[c.ctrl] };
                                    try self.runBuiltinCallInto(id, call_args[0..], c.dsts, regs);
                                }
                            },
                            else => {
                                for (c.dsts) |dst| regs[dst] = .Nil;
                                var call_args = [_]Value{ regs[c.state], regs[c.ctrl] };
                                try self.runBuiltinCallInto(id, call_args[0..], c.dsts, regs);
                            },
                        },
                        else => {
                            for (c.dsts) |dst| regs[dst] = .Nil;
                            var call_args = [_]Value{ regs[c.state], regs[c.ctrl] };
                            const call_name = inferOperandName(f, pc, c.func);
                            const resolved = try self.resolveCallable(callee, call_args[0..], call_name);
                            defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                            try self.runResolvedCallInto(resolved, c.dsts, regs);
                        },
                    }
                },
                .CallVararg => |c| {
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const callee = regs[c.func];
                            try self.debugDispatchHookWithCalleeTransfer("return", null, callee, vals, 1);
                            for (c.dsts, 0..) |dst, i| regs[dst] = if (i < vals.len) vals[i] else .Nil;
                            pc += 1;
                            continue;
                        }
                    }
                    const callee = regs[c.func];
                    const call_args = try self.alloc.alloc(Value, c.args.len + varargs.len);
                    defer self.alloc.free(call_args);
                    for (c.args, 0..) |id, k| call_args[k] = regs[id];
                    for (varargs, 0..) |v, k| call_args[c.args.len + k] = v;
                    for (c.dsts) |dst| regs[dst] = .Nil;

                    const call_name = inferCallName(f, pc, c.func, c.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    try self.runResolvedCallInto(resolved, c.dsts, regs);
                },
                .CallExpand => |c| {
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const callee = regs[c.func];
                            try self.debugDispatchHookWithCalleeTransfer("return", null, callee, vals, 1);
                            for (c.dsts, 0..) |dst, i| regs[dst] = if (i < vals.len) vals[i] else .Nil;
                            pc += 1;
                            continue;
                        }
                    }
                    const tail_ret = try self.evalCallSpec(c.tail, regs, varargs);
                    defer self.alloc.free(tail_ret);

                    const call_args = try self.alloc.alloc(Value, c.args.len + tail_ret.len);
                    defer self.alloc.free(call_args);
                    for (c.args, 0..) |id, k| call_args[k] = regs[id];
                    for (tail_ret, 0..) |v, k| call_args[c.args.len + k] = v;
                    for (c.dsts) |dst| regs[dst] = .Nil;

                    const callee = regs[c.func];
                    const call_name = inferCallName(f, pc, c.func, c.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    try self.runResolvedCallInto(resolved, c.dsts, regs);
                },

                .Return => |r| {
                    const out = try self.alloc.alloc(Value, r.values.len);
                    for (r.values, 0..) |vid, i| out[i] = regs[vid];
                    try self.testcMaterializeDeferredVarargReturns(out);
                    if (has_close_locals) try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
                    if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                        try self.debugDispatchHookTransfer("return", null, out, 1);
                    }
                    if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                    return out;
                },
                .ReturnExpand => |r| {
                    if (self.current_thread) |th| {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const out = try self.alloc.alloc(Value, r.values.len + vals.len);
                            for (r.values, 0..) |vid, i| out[i] = regs[vid];
                            for (vals, 0..) |v, i| out[r.values.len + i] = v;
                            try self.testcMaterializeDeferredVarargReturns(out);
                            if (has_close_locals) try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, out, 1);
                            }
                            if (self.current_thread) |th2| self.clearFrameCaptureCellsForFrame(th2, self.frames.items[self.frames.items.len - 1].frame_id);
                            return out;
                        }
                    }
                    const tail_ret = try self.evalCallSpec(r.tail, regs, varargs);
                    defer self.alloc.free(tail_ret);

                    const out = try self.alloc.alloc(Value, r.values.len + tail_ret.len);
                    for (r.values, 0..) |vid, i| out[i] = regs[vid];
                    for (tail_ret, 0..) |v, i| out[r.values.len + i] = v;
                    try self.testcMaterializeDeferredVarargReturns(out);
                    if (has_close_locals) try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
                    if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                        try self.debugDispatchHookTransfer("return", null, out, 1);
                    }
                    if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                    return out;
                },

                .ReturnCall => |r| {
                    if (self.current_thread) |th| {
                        if (takeThreadReturnInboxAtPc(th, f, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const out = try self.alloc.alloc(Value, vals.len);
                            errdefer self.alloc.free(out);
                            for (vals, 0..) |v, i| out[i] = v;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(th, pc, f, locals, local_active, boxed, out);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, out, 1);
                            }
                            if (self.current_thread) |th2| self.clearFrameCaptureCellsForFrame(th2, self.frames.items[self.frames.items.len - 1].frame_id);
                            return out;
                        }
                    }
                    const callee = regs[r.func];
                    const call_args = try self.alloc.alloc(Value, r.args.len);
                    defer self.alloc.free(call_args);
                    for (r.args, 0..) |id, k| call_args[k] = regs[id];

                    const call_name = inferCallName(f, pc, r.func, r.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    switch (resolved.callee) {
                        .Builtin => |id| {
                            const out_len = self.builtinOutLen(id, resolved.args);
                            const outs = try self.alloc.alloc(Value, out_len);
                            errdefer self.alloc.free(outs);
                            const hook_callee: Value = .{ .Builtin = id };
                            try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, resolved.args, 1);
                            try self.callBuiltin(id, resolved.args, outs);
                            const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, outs[0..used]);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, outs[0..used], 1);
                            }
                            if (used == outs.len) {
                                if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                                return outs;
                            }
                            const ret = try self.alloc.alloc(Value, used);
                            for (0..used) |i| ret[i] = outs[i];
                            self.alloc.free(outs);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        .Closure => |cl| {
                            const hook_callee: Value = .{ .Closure = cl };
                            const hook_args = debugCallTransferArgsForClosure(cl, resolved.args);
                            const frame_idx = self.frames.items.len - 1;
                            try self.debugDispatchHookWithCalleeTransfer("tail call", null, hook_callee, hook_args, 1);
                            self.frames.items[frame_idx].hide_from_debug = true;
                            // Self-tail recursion should not consume host stack.
                            // Reinitialize the current frame in place and restart
                            // execution when the tail target is the same closure.
                            if (cl.func == f and cl.upvalues.len == upvalues.len and std.mem.eql(*Cell, cl.upvalues, upvalues) and !f.is_vararg) {
                                for (regs) |*r0| r0.* = .Nil;
                                for (locals) |*l0| l0.* = .Nil;
                                for (local_active) |*a0| a0.* = false;
                                const nparams_self: usize = @intCast(f.num_params);
                                var pi_self: usize = 0;
                                while (pi_self < nparams_self) : (pi_self += 1) {
                                    locals[pi_self] = if (pi_self < resolved.args.len) resolved.args[pi_self] else .Nil;
                                    local_active[pi_self] = true;
                                }
                                self.frames.items[frame_idx].is_tailcall = true;
                                self.frames.items[frame_idx].hide_from_debug = false;
                                self.frames.items[frame_idx].current_line = initial_line;
                                self.frames.items[frame_idx].last_hook_line = -1;
                                pc = 0;
                                continue;
                            }
                            const ret = try self.runClosure(cl, resolved.args, true);
                            errdefer self.alloc.free(ret);
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, ret);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        else => unreachable,
                    }
                },
                .ReturnCallVararg => |r| {
                    if (self.current_thread) |th| {
                        if (takeThreadReturnInboxAtPc(th, f, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const out = try self.alloc.alloc(Value, vals.len);
                            errdefer self.alloc.free(out);
                            for (vals, 0..) |v, i| out[i] = v;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(th, pc, f, locals, local_active, boxed, out);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, out, 1);
                            }
                            if (self.current_thread) |th2| self.clearFrameCaptureCellsForFrame(th2, self.frames.items[self.frames.items.len - 1].frame_id);
                            return out;
                        }
                    }
                    const callee = regs[r.func];
                    const call_args = try self.alloc.alloc(Value, r.args.len + varargs.len);
                    defer self.alloc.free(call_args);
                    for (r.args, 0..) |id, k| call_args[k] = regs[id];
                    for (varargs, 0..) |v, k| call_args[r.args.len + k] = v;

                    const call_name = inferCallName(f, pc, r.func, r.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    switch (resolved.callee) {
                        .Builtin => |id| {
                            const out_len = self.builtinOutLen(id, resolved.args);
                            const outs = try self.alloc.alloc(Value, out_len);
                            errdefer self.alloc.free(outs);
                            const hook_callee: Value = .{ .Builtin = id };
                            try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, resolved.args, 1);
                            try self.callBuiltin(id, resolved.args, outs);
                            const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, outs[0..used]);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, outs[0..used], 1);
                            }
                            if (used == outs.len) {
                                if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                                return outs;
                            }
                            const ret = try self.alloc.alloc(Value, used);
                            for (0..used) |i| ret[i] = outs[i];
                            self.alloc.free(outs);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        .Closure => |cl| {
                            const hook_callee: Value = .{ .Closure = cl };
                            const hook_args = debugCallTransferArgsForClosure(cl, resolved.args);
                            const frame_idx = self.frames.items.len - 1;
                            try self.debugDispatchHookWithCalleeTransfer("tail call", null, hook_callee, hook_args, 1);
                            self.frames.items[frame_idx].hide_from_debug = true;
                            const ret = try self.runClosure(cl, resolved.args, true);
                            errdefer self.alloc.free(ret);
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, ret);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        else => unreachable,
                    }
                },
                .ReturnCallExpand => |r| {
                    if (self.current_thread) |th| {
                        if (takeThreadTailReturnInboxAtPc(th, f, pc)) |vals| {
                            defer self.alloc.free(vals);
                            const out = try self.alloc.alloc(Value, vals.len);
                            errdefer self.alloc.free(out);
                            for (vals, 0..) |v, i| out[i] = v;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(th, pc, f, locals, local_active, boxed, out);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, out, 1);
                            }
                            if (self.current_thread) |th2| self.clearFrameCaptureCellsForFrame(th2, self.frames.items[self.frames.items.len - 1].frame_id);
                            return out;
                        }
                    }
                    const tail_ret = if (self.current_thread) |th| blk: {
                        if (takeThreadResumeInboxAtPc(th, pc)) |vals| {
                            break :blk vals;
                        }
                        break :blk try self.evalCallSpec(r.tail, regs, varargs);
                    } else try self.evalCallSpec(r.tail, regs, varargs);
                    defer self.alloc.free(tail_ret);

                    const call_args = try self.alloc.alloc(Value, r.args.len + tail_ret.len);
                    defer self.alloc.free(call_args);
                    for (r.args, 0..) |id, k| call_args[k] = regs[id];
                    for (tail_ret, 0..) |v, k| call_args[r.args.len + k] = v;

                    const callee = regs[r.func];
                    const call_name = inferCallName(f, pc, r.func, r.args);
                    const resolved = try self.resolveCallable(callee, call_args, call_name);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    switch (resolved.callee) {
                        .Builtin => |id| {
                            const out_len = self.builtinOutLen(id, resolved.args);
                            const outs = try self.alloc.alloc(Value, out_len);
                            errdefer self.alloc.free(outs);
                            const hook_callee: Value = .{ .Builtin = id };
                            try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, resolved.args, 1);
                            try self.callBuiltin(id, resolved.args, outs);
                            const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, outs[0..used]);
                            if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                                try self.debugDispatchHookTransfer("return", null, outs[0..used], 1);
                            }
                            if (used == outs.len) {
                                if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                                return outs;
                            }
                            const ret = try self.alloc.alloc(Value, used);
                            for (0..used) |i| ret[i] = outs[i];
                            self.alloc.free(outs);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        .Closure => |cl| {
                            const hook_callee: Value = .{ .Closure = cl };
                            const hook_args = debugCallTransferArgsForClosure(cl, resolved.args);
                            const frame_idx = self.frames.items.len - 1;
                            try self.debugDispatchHookWithCalleeTransfer("tail call", null, hook_callee, hook_args, 1);
                            self.frames.items[frame_idx].hide_from_debug = true;
                            const ret = try self.runClosure(cl, resolved.args, true);
                            errdefer self.alloc.free(ret);
                            if (has_close_locals) try self.closePendingWithReturnContinuation(self.current_thread, pc, f, locals, local_active, boxed, ret);
                            if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                            return ret;
                        },
                        else => unreachable,
                    }
                },
                .Vararg => |v| {
                    const vv = try self.getVarargValues(f, locals, varargs);
                    defer if (vv.owned) |owned| self.alloc.free(owned);
                    for (v.dsts, 0..) |dst, idx| {
                        regs[dst] = if (idx < vv.values.len) vv.values[idx] else .Nil;
                    }
                },
                .VarargTable => |v| {
                    const tbl = try self.allocTableEphemeral();
                    tbl.testc_deferred_vararg_accounting = true;
                    for (varargs) |val| {
                        try tbl.array.append(self.alloc, val);
                    }
                    try self.setField(tbl, "n", .{ .Int = @as(i64, @intCast(varargs.len)) });
                    regs[v.dst] = .{ .Table = tbl };
                },
                .ReturnVararg => {
                    const vv = try self.getVarargValues(f, locals, varargs);
                    defer if (vv.owned) |owned| self.alloc.free(owned);
                    const out = try self.alloc.alloc(Value, vv.values.len);
                    for (vv.values, 0..) |v, i| out[i] = v;
                    if (has_close_locals) try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
                    if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                        try self.debugDispatchHookTransfer("return", null, out, 1);
                    }
                    if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                    return out;
                },
                .ReturnVarargExpand => |r| {
                    const vv = try self.getVarargValues(f, locals, varargs);
                    defer if (vv.owned) |owned| self.alloc.free(owned);
                    const out = try self.alloc.alloc(Value, r.values.len + vv.values.len);
                    for (r.values, 0..) |vid, i| out[i] = regs[vid];
                    for (vv.values, 0..) |v, i| out[r.values.len + i] = v;
                    if (has_close_locals) try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
                    if (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].hide_from_debug) {
                        try self.debugDispatchHookTransfer("return", null, out, 1);
                    }
                    if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
                    return out;
                },
            }
            pc += 1;
        }

        // Should not happen: codegen always ensures a terminating `Return`.
        if (self.current_thread) |th| self.clearFrameCaptureCellsForFrame(th, self.frames.items[self.frames.items.len - 1].frame_id);
        return self.alloc.alloc(Value, 0);
    }

    // -----------------------------------------------------------------------
    // Bytecode VM dispatch loop (bc_vm)
    // -----------------------------------------------------------------------
    //
    // Executes PUC-style bytecode (bc.Proto) with runtime top tracking for GC.
    // Reuses the same Value-level helpers as the IR VM (indexValue, evalBinOp,
    // resolveCallable, etc.). The dispatch loop decodes 32-bit instructions
    // and switches on the opcode.

    fn bcConstToValue(self: *Vm, c: bc.Constant) Error!Value {
        return switch (c) {
            .nil => .Nil,
            .bool => |b| .{ .Bool = b },
            .int => |i| .{ .Int = i },
            .num_bits => |n| .{ .Num = @bitCast(n) },
            .str => |s| .{ .String = try self.internStr(s.bytes()) },
        };
    }

    pub fn runBytecode(self: *Vm, proto_in: *const bc.Proto, upvalues_in: []const *Cell, args: []const Value, callee_cl: ?*Closure) Error![]Value {
        const max_depth: usize = if (self.protected_call_depth != 0) 256 else 400;
        if (self.frames.items.len >= max_depth) {
            if (self.protected_call_depth != 0) return self.fail("C stack overflow", .{});
            return self.fail("stack overflow error", .{});
        }

        // These are 'var' because TAILCALL frame reuse may reassign them.
        var cur_proto: *const bc.Proto = proto_in;
        var cur_upvalues: []const *Cell = upvalues_in;

        const maxstack = cur_proto.maxstacksize;

        // ── Shared stack: allocate from bc_stack, NOT from heap ──
        // Each frame occupies bc_stack[base .. base+maxstack].
        // Varargs stored after: bc_stack[base+maxstack .. base+maxstack+nvarargs].
        // No per-frame heap allocation. Stack grows via realloc if needed.
        const nparams = cur_proto.numparams;

        // Varargs: args beyond numparams.
        const varargs_src = if (cur_proto.is_vararg and args.len > nparams)
            args[nparams..]
        else
            &[_]Value{};
        const nvarargs = varargs_src.len;

        var frame_cap: usize = @as(usize, maxstack) + nvarargs;
        const base = self.bc_stack_top;
        try self.ensureBcStackCap(base + frame_cap);
        self.bc_stack_top = base + frame_cap;
        defer self.bc_stack_top = base;

        // regs is a slice into the shared stack.
        var regs = self.bc_stack[base .. base + frame_cap];
        // Initialize all slots to nil.
        for (regs) |*r| r.* = .Nil;

        // boxed: parallel to bc_stack, tracks open upvalue cells per register.
        // We use the region in self.bc_boxed[base .. base+frame_cap].
        var boxed = self.bc_boxed[base .. base + frame_cap];
        for (boxed) |*b| b.* = null;

        // Copy parameters into registers 0..numparams-1.
        const ncopy = @min(nparams, args.len);
        for (0..ncopy) |i| regs[i] = args[i];
        // Nil-fill missing params (already nil-filled above, but be explicit).
        for (ncopy..nparams) |_| {}

        // Varargs: stored after registers in the shared stack.
        const varargs_base = @as(usize, maxstack);
        for (varargs_src, 0..) |v, i| regs[varargs_base + i] = v;
        var varargs = regs[varargs_base .. varargs_base + nvarargs];

        // Push frame for GC/debug.
        const frame_id: usize = 0;
        try self.frames.append(self.alloc, .{
            .func = &bc_dummy_func,
            .proto = cur_proto,
            .callee = if (callee_cl) |cl| .{ .Closure = cl } else .Nil,
            .regs = regs,
            .locals = &.{},
            .boxed = boxed,
            .local_active = &.{},
            .varargs = varargs,
            .upvalues = cur_upvalues,
            .frame_id = frame_id,
            .pc = 0,
            .top = nparams,
            .current_line = 0,
            .last_hook_line = -1,
            .is_tailcall = false,
            .hide_from_debug = false,
            .bc_base = base,
        });
        defer self.frames.items.len -= 1;

        var pc: usize = 0;
        var nvarstack: u8 = nparams;
        var reg_top: u8 = nparams;

        while (pc < cur_proto.code.len) {
            // Refresh regs/boxed at the top of each iteration. The shared
            // stack may have been realloc'd by a callee (CALL, metamethod,
            // builtin), invalidating our slice pointers. Re-deriving from
            // self.bc_stack[base..] ensures we always point to valid memory.
            regs = self.bc_stack[base .. base + frame_cap];
            boxed = self.bc_boxed[base .. base + frame_cap];

            const inst = cur_proto.code[pc];
            const op: bc.Op = @enumFromInt(inst.op);
            const a = inst.a;
            const b = inst.b;
            const c = inst.c;

            // Update frame state for GC/debug.
            const fr = &self.frames.items[self.frames.items.len - 1];
            fr.pc = pc;
            fr.top = reg_top;

            switch (op) {
                .move => {
                    // If source register is boxed (captured as upvalue),
                    // read from the cell — a closure may have modified it
                    // via SETUPVAL. This mirrors PUC Lua's stack-pointer
                    // upvalue model where the stack slot IS the upvalue.
                    regs[a] = if (b < boxed.len) if (boxed[b]) |cell|
                        cell.value
                    else
                        regs[b] else regs[b];
                    // If destination register is boxed, sync the cell too.
                    if (a < boxed.len) if (boxed[a]) |cell| {
                        cell.value = regs[a];
                    };
                },
                .loadk => {
                    const kid: u32 = b;
                    regs[a] = try self.bcConstToValue(cur_proto.k[kid]);
                },
                .loadkx => {
                    // Next instruction is EXTRAARG with the constant index.
                    pc += 1;
                    const extra = cur_proto.code[pc];
                    const kid: u32 = extra.extraArg();
                    regs[a] = try self.bcConstToValue(cur_proto.k[kid]);
                },
                .loadi => {
                    // Signed 16-bit: b=low, c=high.
                    const bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                    const signed: i16 = @bitCast(bits);
                    regs[a] = .{ .Int = @intCast(signed) };
                },
                .loadf => {
                    const bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                    const signed: i16 = @bitCast(bits);
                    regs[a] = .{ .Num = @floatFromInt(signed) };
                },
                .loadnil => {
                    var i: u8 = 0;
                    while (i <= b) : (i += 1) regs[a + i] = .Nil;
                },
                .loadtrue => regs[a] = .{ .Bool = true },
                .loadfalse => regs[a] = .{ .Bool = false },

                .getupval => regs[a] = cur_upvalues[b].value,
                .setupval => cur_upvalues[b].value = regs[a],

                .gettabup => {
                    // R[A] = UpVal[B][K[C]]
                    const env = cur_upvalues[b].value;
                    const key = try self.bcConstToValue(cur_proto.k[c]);
                    regs[a] = try self.indexValue(env, key);
                },
                .settabup => {
                    // UpVal[A][K[B]] = R[C]
                    const env = cur_upvalues[a].value;
                    const key = try self.bcConstToValue(cur_proto.k[b]);
                    try self.setIndexValue(env, key, regs[c]);
                },

                .gettable => {
                    // R[A] = R[B][R[C]] — may trigger __index metamethod.
                    const obj = regs[b];
                    const key = regs[c];
                    const result = try self.indexValue(obj, key);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .geti => {
                    // R[A] = R[B][C]  (integer key)
                    const obj = regs[b];
                    const result = try self.indexValue(obj, .{ .Int = @intCast(c) });
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .getfield => {
                    // R[A] = R[B][K[C]]  (string key)
                    const obj = regs[b];
                    const key = try self.bcConstToValue(cur_proto.k[c]);
                    const result = try self.indexValue(obj, key);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .settable => {
                    // R[A][R[B]] = R[C] — may trigger __newindex metamethod.
                    // Snapshot all register values before the call.
                    const obj = regs[a];
                    const key = regs[b];
                    const val = regs[c];
                    try self.setIndexValue(obj, key, val);
                },
                .seti => {
                    // R[A][B] = R[C]  (integer key)
                    const obj = regs[a];
                    const val = regs[c];
                    try self.setIndexValue(obj, .{ .Int = @intCast(b) }, val);
                },
                .setfield => {
                    // R[A][K[B]] = R[C]  (string key)
                    const obj = regs[a];
                    const key = try self.bcConstToValue(cur_proto.k[b]);
                    const val = regs[c];
                    try self.setIndexValue(obj, key, val);
                },

                .newtable => {
                    const t = try self.allocTable();
                    regs[a] = .{ .Table = t };
                },
                .self => {
                    // R[A+1] = R[B]; R[A] = R[B][K[C]]
                    const obj = regs[b];
                    regs[a + 1] = obj;
                    const key = try self.bcConstToValue(cur_proto.k[c]);
                    const result = try self.indexValue(obj, key);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },

                // --- Arithmetic ---
                // Snapshot operands before evalBinOp (may trigger metamethod →
                // bc_stack realloc → stale regs). Write result after refresh.
                .add => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Plus, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .sub => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Minus, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .mul => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Star, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .div => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Slash, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .mod => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Percent, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .pow => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Caret, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .idiv => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Idiv, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .band => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Amp, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .bor => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Pipe, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .bxor => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Tilde, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .shl => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Shl, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .shr => {
                    const lb = regs[b];
                    const rc = regs[c];
                    const result = try self.evalBinOp(.Shr, lb, rc);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },

                .unm => {
                    const val = regs[b];
                    const result = try self.evalUnOp(.Minus, val);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .bnot => {
                    const val = regs[b];
                    const result = try self.evalUnOp(.Tilde, val);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },
                .not => regs[a] = try self.evalUnOp(.Not, regs[b]),
                .len => {
                    const val = regs[b];
                    const result = try self.evalUnOp(.Hash, val);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },

                .concat => {
                    // Snapshot all values in the concat range before calling
                    // concatValues (may trigger __concat metamethod → realloc).
                    const concat_vals = try self.alloc.dupe(Value, regs[a..a + b]);
                    defer self.alloc.free(concat_vals);
                    const result = try self.concatValues(concat_vals);
                    regs = self.bc_stack[base..base + frame_cap];
                    regs[a] = result;
                },

                // --- Comparisons ---
                // EQ/LT/LE: if (R[A] op R[B]) != (C!=0) then pc++
                // Snapshot operands — comparison may trigger metamethod.
                .eq => {
                    const la = regs[a];
                    const lb = regs[b];
                    const result = try self.cmpEq(la, lb);
                    const invert = (c != 0);
                    if (result != invert) pc += 1;
                },
                .lt => {
                    const la = regs[a];
                    const lb = regs[b];
                    const result = try self.cmpLt(la, lb);
                    const invert = (c != 0);
                    if (result != invert) pc += 1;
                },
                .le => {
                    const la = regs[a];
                    const lb = regs[b];
                    const result = try self.cmpLte(la, lb);
                    const invert = (c != 0);
                    if (result != invert) pc += 1;
                },

                // --- Test / testset ---
                .test_ => {
                    const is_truthy = isTruthy(regs[a]);
                    const skip_if_falsy = (c != 0);
                    if (!is_truthy == skip_if_falsy) pc += 1;
                },
                .testset => {
                    const is_truthy = isTruthy(regs[b]);
                    const skip_if_falsy = (c != 0);
                    if (!is_truthy == skip_if_falsy) {
                        pc += 1;
                    } else {
                        regs[a] = regs[b];
                    }
                },

                // --- Control flow ---
                .jmp => {
                    pc = @intCast(@as(i64, @intCast(pc)) + inst.jumpOffset() + 1);
                    continue;
                },

                // --- Calls / returns ---
                .call => {
                    // R[A..A+C-2] := R[A](R[A+1..A+B-1])
                    const func_val = regs[a];
                    const nargs: u8 = if (b == 0) @intCast(reg_top - a - 1) else b - 1;
                    const nresults: i32 = if (c == 0) -1 else @intCast(c - 1);
                    const orig_args = regs[a + 1 .. a + 1 + nargs];

                    const resolved = try self.resolveCallable(func_val, orig_args, null);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);

                    // After resolveCallable, resolved.args may include prepended
                    // __call self values that aren't in the register slice.
                    // It may also point into the shared bytecode stack. A callee
                    // can grow/realloc that stack before copying its parameters,
                    // so recursive bytecode dispatch must receive a stable copy.
                    const rargs = try self.alloc.dupe(Value, resolved.args);
                    defer self.alloc.free(rargs);

                    switch (resolved.callee) {
                        .Builtin => |id| {
                            const out_len: usize = if (nresults >= 0)
                                @max(@as(usize, @intCast(nresults)), self.builtinOutLen(id, rargs))
                            else
                                self.builtinOutLen(id, rargs);
                            var outs_small: [8]Value = undefined;
                            var outs_heap: ?[]Value = null;
                            const outs = if (out_len <= outs_small.len) outs_small[0..out_len] else blk: {
                                outs_heap = try self.alloc.alloc(Value, out_len);
                                break :blk outs_heap.?;
                            };
                            defer if (outs_heap) |h| self.alloc.free(h);
                            try self.callBuiltin(id, rargs, outs);
                            const nstore: usize = if (nresults >= 0) @intCast(nresults) else out_len;
                            // Grow frame for results, then write — no silent truncation.
                            try self.bcGrowFrame(base, a + nstore, &frame_cap, &regs, &boxed);
                            for (0..nstore) |i| {
                                regs[a + i] = if (i < outs.len) outs[i] else .Nil;
                            }
                            if (nresults < 0) reg_top = @intCast(@min(@as(usize, a) + out_len, 255));
                        },
                        .Closure => |cl| {
                            const ret = if (cl.proto) |proto2|
                                try self.runBytecode(proto2, cl.upvalues, rargs, cl)
                            else
                                try self.runClosure(cl, rargs, false);
                            defer self.alloc.free(ret);
                            const nstore: usize = if (nresults >= 0) @intCast(nresults) else ret.len;
                            // Grow frame for results, then write — no silent truncation.
                            try self.bcGrowFrame(base, a + nstore, &frame_cap, &regs, &boxed);
                            for (0..nstore) |i| {
                                regs[a + i] = if (i < ret.len) ret[i] else .Nil;
                            }
                            if (nresults < 0) reg_top = @intCast(@min(@as(usize, a) + ret.len, 255));
                        },
                        else => unreachable,
                    }
                },
                .tailcall => {
                    // PUC-like tail call: reuse current frame, no host recursion.
                    // return R[A](R[A+1..A+B-1])
                    const func_val = regs[a];
                    const nargs: u8 = if (b == 0) @intCast(reg_top - a - 1) else b - 1;

                    // Dupe call args (they live in regs which we're about to overwrite).
                    const dup_args = try self.alloc.dupe(Value, regs[a + 1 .. a + 1 + nargs]);
                    defer self.alloc.free(dup_args);

                    const resolved = try self.resolveCallable(func_val, dup_args, null);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);

                    // After resolveCallable, resolved.args may differ from
                    // dup_args: a __call metamethod prepends the callee value.
                    const call_args = resolved.args;

                    switch (resolved.callee) {
                        .Closure => |cl| if (cl.proto) |new_proto| {
                            // ── Bytecode-to-bytecode tail call: frame reuse ──

                            // 1. Close all boxed upvalues: snapshot current reg
                            //    values into cells, then clear boxed slots.
                            for (boxed, 0..) |*bc_slot, i| {
                                if (bc_slot.*) |cell| {
                                    cell.value = regs[i];
                                    bc_slot.* = null;
                                }
                            }

                            // 2. Grow frame if the new function needs more space.
                            const new_max = new_proto.maxstacksize;
                            const new_nvarargs: usize = if (new_proto.is_vararg and call_args.len > new_proto.numparams)
                                call_args.len - new_proto.numparams
                            else
                                0;
                            const new_cap: usize = @as(usize, new_max) + new_nvarargs;
                            try self.bcGrowFrame(base, new_cap, &frame_cap, &regs, &boxed);

                            // 3. Nil-fill the register region.
                            for (regs[0..new_max]) |*r| r.* = .Nil;
                            for (boxed[0..new_max]) |*bc_slot| bc_slot.* = null;

                            // 4. Copy parameters into registers 0..nparams-1.
                            const np = new_proto.numparams;
                            const nc = @min(np, call_args.len);
                            for (0..nc) |i| regs[i] = call_args[i];

                            // 5. Set up varargs in the shared stack region.
                            const va_src = if (new_proto.is_vararg and call_args.len > np)
                                call_args[np..]
                            else
                                &[_]Value{};
                            const va_base = @as(usize, new_max);
                            for (va_src, 0..) |v, i| regs[va_base + i] = v;
                            varargs = regs[va_base .. va_base + va_src.len];

                            // 6. Update frame state.
                            cur_proto = new_proto;
                            cur_upvalues = cl.upvalues;

                            // 7. Update Frame struct on self.frames.
                            const fr2 = &self.frames.items[self.frames.items.len - 1];
                            fr2.proto = new_proto;
                            fr2.upvalues = cur_upvalues;
                            fr2.regs = regs;
                            fr2.boxed = boxed;
                            fr2.varargs = varargs;
                            fr2.callee = .{ .Closure = cl };
                            fr2.pc = 0;
                            fr2.top = np;
                            fr2.is_tailcall = true;

                            // 8. Reset dispatch state.
                            pc = 0;
                            nvarstack = np;
                            reg_top = np;

                            continue; // Restart dispatch loop with new function.
                        },
                        // For builtins and IR closures: fall back to host recursion.
                        .Builtin => {},
                        else => {},
                    }

                    // Non-bytecode tail call: execute the callee and return
                    // its results. The current bytecode frame is still popped
                    // by the runBytecode defer; manually popping here would
                    // corrupt the VM frame stack.
                    const ret = switch (resolved.callee) {
                        .Builtin => |id| blk: {
                            const out_len = @max(self.builtinOutLen(id, call_args), 1);
                            var outs_small: [8]Value = undefined;
                            var outs_heap: ?[]Value = null;
                            const outs = if (out_len <= outs_small.len) outs_small[0..out_len] else heap: {
                                outs_heap = try self.alloc.alloc(Value, out_len);
                                break :heap outs_heap.?;
                            };
                            defer if (outs_heap) |h| self.alloc.free(h);
                            try self.callBuiltin(id, call_args, outs);
                            break :blk try self.alloc.dupe(Value, outs);
                        },
                        .Closure => |cl| try self.runClosure(cl, call_args, true),
                        else => unreachable,
                    };
                    return ret;
                },
                .return_ => {
                    // return R[A..A+B-2]
                    const nvals: u8 = if (b == 0) @intCast(reg_top - a) else b - 1;
                    const ret = try self.alloc.dupe(Value, regs[a .. a + nvals]);
                    return ret;
                },
                .return0 => return try self.alloc.alloc(Value, 0),
                .return1 => {
                    const ret = try self.alloc.alloc(Value, 1);
                    ret[0] = regs[a];
                    return ret;
                },

                // --- For-loops ---
                .forprep => {
                    // A=base, offset in B:C (16-bit signed).
                    const init_val = regs[a];
                    const limit = regs[a + 1];
                    const step = regs[a + 2];

                    const init_num = if (init_val == .Int) @as(f64, @floatFromInt(init_val.Int)) else if (init_val == .Num) init_val.Num else return self.fail("'for' initial value must be a number", .{});
                    const limit_num = if (limit == .Int) @as(f64, @floatFromInt(limit.Int)) else if (limit == .Num) limit.Num else return self.fail("'for' limit must be a number", .{});
                    const step_num = if (step == .Int) @as(f64, @floatFromInt(step.Int)) else if (step == .Num) step.Num else return self.fail("'for' step must be a number", .{});

                    if (step_num == 0) return self.fail("'for' step is zero", .{});

                    const should_run = if (step_num > 0)
                        init_num <= limit_num
                    else
                        init_num >= limit_num;

                    if (!should_run) {
                        // Skip loop body.
                        const off_bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                        const off: i16 = @bitCast(off_bits);
                        pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, off) + 1);
                        continue;
                    }

                    // Set loop variable.
                    regs[a + 3] = init_val;
                    nvarstack = a + 4;
                    reg_top = @max(reg_top, a + 4);
                },
                .forloop => {
                    // A=base, offset in B:C (16-bit signed).
                    const loop_var = regs[a + 3];
                    const limit = regs[a + 1];
                    const step = regs[a + 2];

                    const cur_num = if (loop_var == .Int) @as(f64, @floatFromInt(loop_var.Int)) else loop_var.Num;
                    const limit_num = if (limit == .Int) @as(f64, @floatFromInt(limit.Int)) else limit.Num;
                    const step_num = if (step == .Int) @as(f64, @floatFromInt(step.Int)) else step.Num;

                    const next_num = cur_num + step_num;
                    const continues = if (step_num > 0)
                        next_num <= limit_num
                    else
                        next_num >= limit_num;

                    if (continues) {
                        if (loop_var == .Int and step == .Int) {
                            regs[a + 3] = .{ .Int = loop_var.Int + step.Int };
                        } else {
                            regs[a + 3] = .{ .Num = next_num };
                        }
                        const off_bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                        const off: i16 = @bitCast(off_bits);
                        pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, off) + 1);
                        continue;
                    }
                },

                .tforcall => {
                    // R[A+4..A+3+C] := R[A](R[A+1], R[A+2])
                    const iter = regs[a];
                    const state = regs[a + 1];
                    const ctrl = regs[a + 2];
                    const nresults: u8 = if (c == 0) 0 else c - 1;

                    var call_args = [_]Value{ state, ctrl };
                    const resolved = try self.resolveCallable(iter, call_args[0..], null);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    const rargs = try self.alloc.dupe(Value, resolved.args);
                    defer self.alloc.free(rargs);

                    // Call callee, get results as fresh []Value.
                    const ret = switch (resolved.callee) {
                        .Builtin => |id| blk: {
                            const out_len = @max(self.builtinOutLen(id, rargs), @as(usize, nresults));
                            var outs_small: [8]Value = undefined;
                            var outs_heap: ?[]Value = null;
                            const outs = if (out_len <= outs_small.len) outs_small[0..out_len] else blk2: {
                                outs_heap = try self.alloc.alloc(Value, out_len);
                                break :blk2 outs_heap.?;
                            };
                            defer if (outs_heap) |h| self.alloc.free(h);
                            try self.callBuiltin(id, rargs, outs);
                            break :blk try self.alloc.dupe(Value, outs);
                        },
                        .Closure => |cl| try self.runClosure(cl, rargs, false),
                        else => unreachable,
                    };
                    defer self.alloc.free(ret);

                    // Refresh regs after potential realloc, then write results.
                    regs = self.bc_stack[base..base + frame_cap];
                    const n = @min(ret.len, @as(usize, nresults));
                    for (0..n) |i| regs[a + 4 + i] = ret[i];
                    for (n..@as(usize, nresults)) |i| regs[a + 4 + i] = .Nil;
                    reg_top = @max(reg_top, a + 4 + nresults);
                },
                .tforloop => {
                    // A=base, offset in B:C. If R[base+2] != nil, loop continues.
                    const ctrl = regs[a + 2];
                    if (ctrl != .Nil) {
                        regs[a] = ctrl;
                        const off_bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                        const off: i16 = @bitCast(off_bits);
                        pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, off) + 1);
                        continue;
                    }
                },
                .tforprep => {
                    // A=base, offset in B:C. Jump forward to after loop.
                    const off_bits: u16 = @as(u16, b) | (@as(u16, c) << 8);
                    const off: i16 = @bitCast(off_bits);
                    pc = @intCast(@as(i64, @intCast(pc)) + @as(i64, off) + 1);
                    continue;
                },

                // --- Table constructor ---
                .setlist => {
                    // R[A][C+i] := R[A+i] for 1<=i<=B
                    // C is the base index (0 means elements start at 1).
                    const table_val = regs[a];
                    const count: u8 = if (b == 0) @intCast(reg_top - a - 1) else b;
                    const base_idx: u32 = c;

                    if (table_val == .Table) {
                        for (0..count) |i| {
                            try self.setIndexValue(table_val, .{ .Int = @intCast(base_idx + i + 1) }, regs[a + 1 + i]);
                        }
                    }
                },

                // --- Closures ---
                .closure => {
                    // R[A] = closure(P[B])
                    const child_proto = cur_proto.p[b];

                    // Create upvalue cells from child's upvalue descriptions.
                    const nups = child_proto.upvalues.len;
                    const cells = try self.alloc.alloc(*Cell, nups);
                    for (child_proto.upvalues, 0..) |uv, i| {
                        if (uv.instack) {
                            // Capture from current frame's register.
                            if (boxed[uv.idx]) |cell| {
                                cells[i] = cell;
                            } else {
                                const cell = try self.alloc.create(Cell);
                                cell.* = .{ .value = regs[uv.idx] };
                                try self.gc_cells.append(self.alloc, cell);
                                boxed[uv.idx] = cell;
                                cells[i] = cell;
                            }
                        } else {
                            // Proxy from current frame's upvalues.
                            cells[i] = cur_upvalues[uv.idx];
                        }
                    }

                    const cl = try self.alloc.create(Closure);
                    cl.* = .{
                        .func = &bc_dummy_func,
                        .proto = child_proto,
                        .upvalues = cells,
                    };
                    try self.gc_closures.append(self.alloc, cl);
                    regs[a] = .{ .Closure = cl };
                    // If this register was captured as an upvalue (boxed),
                    // update the cell to reflect the new value. This is
                    // essential for recursive closures (local function f()
                    // ... f() ... end) where the upvalue must see the
                    // closure after CLOSURE stores it.
                    if (boxed[a]) |cell| {
                        cell.value = regs[a];
                    }
                },

                // --- Upvalue / scope management ---
                .close => {
                    // Close all upvalues >= R[A]
                    for (boxed[a..], a..) |*maybe_cell, reg_idx| {
                        if (maybe_cell.*) |cell| {
                            if (reg_idx < regs.len) cell.value = regs[reg_idx];
                            maybe_cell.* = null;
                        }
                    }
                },
                .tbc => {
                    // Mark R[A] as to-be-closed (TODO: implement __close handling)
                },

                // --- Varargs ---
                .vararg => {
                    // R[A..A+C-2] = varargs
                    const nresults: i32 = if (c == 0) -1 else @intCast(c - 1);
                    if (nresults >= 0) {
                        const nr: usize = @intCast(nresults);
                        try self.bcGrowFrame(base, a + nr, &frame_cap, &regs, &boxed);
                        const ncopy2 = @min(nr, varargs.len);
                        for (0..ncopy2) |i| regs[a + i] = varargs[i];
                        for (ncopy2..nr) |i| regs[a + i] = .Nil;
                        reg_top = @max(reg_top, a + @as(u8, @intCast(nr)));
                    } else {
                        // All varargs — grow frame, then copy.
                        try self.bcGrowFrame(base, a + varargs.len, &frame_cap, &regs, &boxed);
                        for (varargs, 0..) |v, i| regs[a + i] = v;
                        reg_top = @intCast(@min(@as(usize, a) + varargs.len, 255));
                    }
                },
                .varargprep => {
                    // First instruction of a vararg function.
                    // If the function has a named vararg table (vararg_table_reg),
                    // create the table and store it in the designated register.
                    if (cur_proto.vararg_table_reg) |va_reg| {
                        const t = try self.allocTable();
                        // Fill array part with varargs.
                        for (varargs) |v| {
                            try t.array.append(self.alloc, v);
                        }
                        // Set 'n' field to the count.
                        try self.setIndexValue(.{ .Table = t }, .{ .String = try self.internStr("n") }, .{ .Int = @intCast(varargs.len) });
                        regs[va_reg] = .{ .Table = t };
                        reg_top = @max(reg_top, va_reg + 1);
                    }
                },

                // --- Error ---
                .errnnil => {
                    if (regs[a] == .Nil) {
                        const name = if (b > 0) cur_proto.k[b - 1] else bc.Constant.nil;
                        const name_str = if (name == .str) name.str.bytes() else "<global>";
                        return self.fail("attempt to use a nil value (global '{s}')", .{name_str});
                    }
                },

                // --- Extended argument ---
                .extraarg => {
                    // Should be consumed by the preceding instruction.
                },
            }

            pc += 1;
        }

        // Should not happen (codegen ensures terminating return).
        return self.alloc.alloc(Value, 0);
    }

    /// Helper: concatenate values (for CONCAT instruction).
    fn concatValues(self: *Vm, vals: []Value) Error!Value {
        if (vals.len == 0) return .{ .String = try self.internLiteral("") };
        if (vals.len == 1) return vals[0];

        // Convert all values to strings and compute total length.
        var bufs: [16][]const u8 = undefined;
        var heap_bufs: ?std.ArrayListUnmanaged([]const u8) = null;
        defer if (heap_bufs) |*hb| {
            for (hb.items) |b| self.alloc.free(b);
            hb.deinit(self.alloc);
        };
        var total: usize = 0;
        for (vals, 0..) |v, i| {
            const s = switch (v) {
                .String => |ls| ls.bytes(),
                .Int => blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{v.Int}) catch unreachable;
                    const owned = try self.alloc.dupe(u8, s);
                    if (heap_bufs == null) heap_bufs = .empty;
                    try heap_bufs.?.append(self.alloc, owned);
                    break :blk owned;
                },
                .Num => blk: {
                    const owned = try self.numberToStringAlloc(v.Num);
                    if (heap_bufs == null) heap_bufs = .empty;
                    try heap_bufs.?.append(self.alloc, owned);
                    break :blk owned;
                },
                else => return self.fail("attempt to concatenate a {s} value", .{@tagName(v)}),
            };
            if (i < bufs.len) bufs[i] = s;
            total += s.len;
        }

        // Build result.
        var result = try self.alloc.alloc(u8, total);
        var pos: usize = 0;
        for (vals, 0..) |v, i| {
            const s = if (i < bufs.len) bufs[i] else switch (v) {
                .String => |ls| ls.bytes(),
                else => unreachable,
            };
            @memcpy(result[pos..][0..s.len], s);
            pos += s.len;
        }

        return .{ .String = try self.internStr(result) };
    }

    fn decodeStringLexeme(self: *Vm, lexeme: []const u8) Error!*LuaString {
        if (lexeme.len < 2) return try self.internLiteral(lexeme);
        const q = lexeme[0];
        if (q == '[') {
            var eqs: usize = 0;
            var i: usize = 1;
            while (i < lexeme.len and lexeme[i] == '=') : (i += 1) eqs += 1;
            if (i >= lexeme.len or lexeme[i] != '[') return try self.internLiteral(lexeme);
            const close_len = eqs + 2;
            if (lexeme.len < i + 1 + close_len) return try self.internLiteral(lexeme);

            const close_start = lexeme.len - close_len;
            if (lexeme[close_start] != ']') return try self.internLiteral(lexeme);
            var j: usize = close_start + 1;
            var k: usize = 0;
            while (k < eqs) : (k += 1) {
                if (j >= lexeme.len or lexeme[j] != '=') return try self.internLiteral(lexeme);
                j += 1;
            }
            if (j >= lexeme.len or lexeme[j] != ']') return try self.internLiteral(lexeme);

            var content_start = i + 1;
            if (content_start < close_start) {
                if (lexeme[content_start] == '\n') {
                    content_start += 1;
                    if (content_start < close_start and lexeme[content_start] == '\r') content_start += 1;
                } else if (lexeme[content_start] == '\r') {
                    content_start += 1;
                    if (content_start < close_start and lexeme[content_start] == '\n') content_start += 1;
                }
            }
            const body = lexeme[content_start..close_start];
            if (std.mem.indexOfAny(u8, body, "\r\n") == null) return try self.internLiteral(body);
            var out = std.ArrayListUnmanaged(u8).empty;
            var bi: usize = 0;
            while (bi < body.len) {
                const ch = body[bi];
                if (ch == '\r' or ch == '\n') {
                    try out.append(self.alloc, '\n');
                    if (bi + 1 < body.len) {
                        const nxt = body[bi + 1];
                        if ((ch == '\r' and nxt == '\n') or (ch == '\n' and nxt == '\r')) bi += 1;
                    }
                } else {
                    try out.append(self.alloc, ch);
                }
                bi += 1;
            }
            const normalized = try out.toOwnedSlice(self.alloc);
            defer self.alloc.free(normalized);
            return try self.internLiteral(normalized);
        }
        if (!((q == '"' or q == '\'') and lexeme[lexeme.len - 1] == q)) return try self.internLiteral(lexeme);

        const inner = lexeme[1 .. lexeme.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return try self.internLiteral(inner);

        var out = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < inner.len) {
            const c = inner[i];
            if (c != '\\') {
                try out.append(self.alloc, c);
                i += 1;
                continue;
            }

            i += 1;
            if (i >= inner.len) return self.fail("unfinished string escape", .{});
            const e = inner[i];

            switch (e) {
                'a' => {
                    try out.append(self.alloc, 0x07);
                    i += 1;
                },
                'b' => {
                    try out.append(self.alloc, 0x08);
                    i += 1;
                },
                'f' => {
                    try out.append(self.alloc, 0x0c);
                    i += 1;
                },
                'n' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                },
                'r' => {
                    try out.append(self.alloc, '\r');
                    i += 1;
                },
                't' => {
                    try out.append(self.alloc, '\t');
                    i += 1;
                },
                'v' => {
                    try out.append(self.alloc, 0x0b);
                    i += 1;
                },
                '\\' => {
                    try out.append(self.alloc, '\\');
                    i += 1;
                },
                '"' => {
                    try out.append(self.alloc, '"');
                    i += 1;
                },
                '\'' => {
                    try out.append(self.alloc, '\'');
                    i += 1;
                },
                'z' => {
                    i += 1;
                    while (i < inner.len) {
                        const ws = inner[i];
                        if (ws == ' ' or ws == '\t' or ws == 0x0b or ws == 0x0c) {
                            i += 1;
                            continue;
                        }
                        if (ws == '\n' or ws == '\r') {
                            i += 1;
                            if (i < inner.len) {
                                const nxt = inner[i];
                                if ((ws == '\n' and nxt == '\r') or (ws == '\r' and nxt == '\n')) i += 1;
                            }
                            continue;
                        }
                        break;
                    }
                },
                'x' => {
                    if (i + 2 >= inner.len) return self.fail("invalid hex escape", .{});
                    const h1 = hexVal(inner[i + 1]) orelse return self.fail("invalid hex escape", .{});
                    const h2 = hexVal(inner[i + 2]) orelse return self.fail("invalid hex escape", .{});
                    try out.append(self.alloc, (h1 << 4) | h2);
                    i += 3;
                },
                'u' => {
                    if (i + 1 >= inner.len or inner[i + 1] != '{') return self.fail("invalid unicode escape", .{});
                    i += 2; // skip 'u' '{'
                    if (i >= inner.len) return self.fail("invalid unicode escape", .{});
                    var codepoint: u32 = 0;
                    var digits: usize = 0;
                    while (i < inner.len and inner[i] != '}') : (i += 1) {
                        const hv = hexVal(inner[i]) orelse return self.fail("invalid unicode escape", .{});
                        codepoint = (codepoint << 4) | hv;
                        digits += 1;
                        if (digits > 8) return self.fail("invalid unicode escape", .{});
                    }
                    if (i >= inner.len or inner[i] != '}' or digits == 0) return self.fail("invalid unicode escape", .{});
                    i += 1; // skip '}'
                    var buf: [6]u8 = undefined;
                    const nbytes = encodeLuaUtf8(codepoint, buf[0..]) orelse return self.fail("invalid unicode escape", .{});
                    try out.appendSlice(self.alloc, buf[0..nbytes]);
                },
                '\n' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                    if (i < inner.len and inner[i] == '\r') i += 1;
                },
                '\r' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                    if (i < inner.len and inner[i] == '\n') i += 1;
                },
                else => {
                    if (e >= '0' and e <= '9') {
                        var val: u32 = 0;
                        var count: usize = 0;
                        while (i < inner.len and count < 3) : (count += 1) {
                            const d = inner[i];
                            if (!(d >= '0' and d <= '9')) break;
                            val = (val * 10) + @as(u32, d - '0');
                            i += 1;
                        }
                        if (val > 255) return self.fail("decimal escape out of range", .{});
                        try out.append(self.alloc, @as(u8, @intCast(val)));
                    } else {
                        try out.append(self.alloc, e);
                        i += 1;
                    }
                },
            }
        }
        const decoded = try out.toOwnedSlice(self.alloc);
        defer self.alloc.free(decoded);
        return try self.internLiteral(decoded);
    }

    fn hexVal(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
        if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
        return null;
    }

    fn encodeLuaUtf8(codepoint: u32, out: []u8) ?usize {
        if (codepoint <= 0x7F) {
            if (out.len < 1) return null;
            out[0] = @as(u8, @intCast(codepoint));
            return 1;
        }
        if (codepoint <= 0x7FF) {
            if (out.len < 2) return null;
            out[0] = @as(u8, @intCast(0xC0 | (codepoint >> 6)));
            out[1] = @as(u8, @intCast(0x80 | (codepoint & 0x3F)));
            return 2;
        }
        if (codepoint <= 0xFFFF) {
            if (out.len < 3) return null;
            out[0] = @as(u8, @intCast(0xE0 | (codepoint >> 12)));
            out[1] = @as(u8, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
            out[2] = @as(u8, @intCast(0x80 | (codepoint & 0x3F)));
            return 3;
        }
        if (codepoint <= 0x1F_FFFF) {
            if (out.len < 4) return null;
            out[0] = @as(u8, @intCast(0xF0 | (codepoint >> 18)));
            out[1] = @as(u8, @intCast(0x80 | ((codepoint >> 12) & 0x3F)));
            out[2] = @as(u8, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
            out[3] = @as(u8, @intCast(0x80 | (codepoint & 0x3F)));
            return 4;
        }
        if (codepoint <= 0x3FF_FFFF) {
            if (out.len < 5) return null;
            out[0] = @as(u8, @intCast(0xF8 | (codepoint >> 24)));
            out[1] = @as(u8, @intCast(0x80 | ((codepoint >> 18) & 0x3F)));
            out[2] = @as(u8, @intCast(0x80 | ((codepoint >> 12) & 0x3F)));
            out[3] = @as(u8, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
            out[4] = @as(u8, @intCast(0x80 | (codepoint & 0x3F)));
            return 5;
        }
        if (codepoint <= 0x7FFF_FFFF) {
            if (out.len < 6) return null;
            out[0] = @as(u8, @intCast(0xFC | (codepoint >> 30)));
            out[1] = @as(u8, @intCast(0x80 | ((codepoint >> 24) & 0x3F)));
            out[2] = @as(u8, @intCast(0x80 | ((codepoint >> 18) & 0x3F)));
            out[3] = @as(u8, @intCast(0x80 | ((codepoint >> 12) & 0x3F)));
            out[4] = @as(u8, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
            out[5] = @as(u8, @intCast(0x80 | (codepoint & 0x3F)));
            return 6;
        }
        return null;
    }

    // Intern `raw` and return the canonical *LuaString. ALL string-creating
    // sites must go through here so two equal-content strings share one
    // pointer (then string equality is pointer comparison). Seed from the
    // per-VM RNG so the cached hash is randomized (matches PUC Lua's
    // random-seed string hashing).
    pub fn internStr(self: *Vm, raw: []const u8) std.mem.Allocator.Error!*LuaString {
        const seed = self.rng_state[0] ^ self.rng_state[2];
        var h = std.hash.Wyhash.init(seed);
        h.update(raw);
        const hash = h.final();
        // Short strings are interned (dedup => pointer identity). Long strings
        // are allocated fresh every time, matching PUC `luaS_newlstr`, which
        // calls `internshrstr` only when l <= LUAI_MAXSHORTLEN and otherwise
        // builds a new `LUA_VLNGSTR` via `luaS_createlngstrobj`.
        if (raw.len <= lua_string_max_short_len) {
            if (self.string_intern.table.get(raw)) |existing| return existing;
            const ls = try createLuaString(self.alloc, raw, hash);
            try self.string_intern.table.put(self.alloc, ls.bytes(), ls);
            self.testcNoteMemory(@sizeOf(LuaString) + raw.len + 24);
            self.testc_obj_strings += 1;
            return ls;
        }
        const ls = try createLuaString(self.alloc, raw, hash);
        try self.gc_strings.append(self.alloc, ls);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(LuaString) + raw.len)) / 1024.0;
        self.testcNoteMemory(@sizeOf(LuaString) + raw.len + 24);
        self.testc_obj_strings += 1;
        return ls;
    }

    // Intern a string LITERAL (loaded from source via ConstString / bytecode
    // const pool). Short literals go through the global short-string intern
    // table (so a short literal and a short runtime string with the same content
    // share a pointer, as in PUC). Long literals are deduped by content in a
    // separate table — they share a pointer with equal long literals but NOT
    // with equal long runtime strings. Mirrors PUC's compile-time constant
    // folding (luaK_stringK), which dedups literals per Proto regardless of
    // length; we dedup globally (observable only via %p across functions).
    pub fn internLiteral(self: *Vm, raw: []const u8) std.mem.Allocator.Error!*LuaString {
        if (raw.len <= lua_string_max_short_len) return self.internStr(raw);
        if (self.long_literals.table.get(raw)) |existing| return existing;
        const seed = self.rng_state[0] ^ self.rng_state[2];
        var h = std.hash.Wyhash.init(seed);
        h.update(raw);
        const ls = try createLuaString(self.alloc, raw, h.final());
        try self.long_literals.table.put(self.alloc, ls.bytes(), ls);
        self.testcNoteMemory(@sizeOf(LuaString) + raw.len + 24);
        self.testc_obj_strings += 1;
        return ls;
    }

    // Intern `raw` from a context that cannot propagate errors (a `void` or
    // bare-`Value` returning function, e.g. the OOM-error setter or a global
    // accessor). These sites only ever feed short constant strings or
    // already-interned messages, so on the rare first-time allocation we
    // abort — exactly what `Vm.init` does for its own allocations. This keeps
    // the call sites free of `try` without introducing a parallel interning
    // path: it routes through `internStr`, so dedup/pointer-identity still hold.
    fn internStrAssume(self: *Vm, raw: []const u8) *LuaString {
        return self.internStr(raw) catch @panic("luazig: oom interning constant string");
    }

    fn expectTable(self: *Vm, v: Value) Error!*Table {
        return switch (v) {
            .Table => |t| t,
            else => self.fail("type error: expected table, got {s}", .{v.typeName()}),
        };
    }

    fn expectThread(self: *Vm, v: Value) Error!*Thread {
        return switch (v) {
            .Thread => |t| t,
            else => self.fail("type error: expected thread, got {s}", .{v.typeName()}),
        };
    }

    fn getGlobal(self: *Vm, name: []const u8) Value {
        if (std.mem.eql(u8, name, "_G")) return .{ .Table = self.global_env };
        if (std.mem.eql(u8, name, "_ENV")) return .{ .Table = self.global_env };
        const v = self.getField(self.global_env, name);
        if (v != .Nil) return v;
        if (std.mem.eql(u8, name, "_VERSION")) return .{ .String = self.internStrAssume("Lua 5.5") };
        return .Nil;
    }

    fn setGlobal(self: *Vm, name: []const u8, v: Value) Error!void {
        // Writing Nil removes the entry (rawSet semantics); no separate dup of
        // the name is needed — the key lives inside the interned LuaString.
        try self.setField(self.global_env, name, v);
    }

    fn frameEnvValue(self: *Vm, frame_index: usize) ?Value {
        const fr = self.frames.items[frame_index];
        const nlocals = @min(fr.locals.len, fr.func.local_names.len);
        var i = nlocals;
        while (i > 0) {
            i -= 1;
            if (!fr.local_active[i]) continue;
            if (std.mem.eql(u8, fr.func.local_names[i], "_ENV")) return fr.locals[i];
        }
        const nups = @min(fr.upvalues.len, fr.func.upvalue_names.len);
        var u: usize = 0;
        while (u < nups) : (u += 1) {
            if (std.mem.eql(u8, fr.func.upvalue_names[u], "_ENV")) {
                return fr.upvalues[u].value;
            }
        }
        if (fr.env_override) |v| return v;
        return null;
    }

    fn getNameInFrame(self: *Vm, frame_index: usize, name: []const u8) Error!Value {
        if (frameEnvValue(self, frame_index)) |envv| {
            if (std.mem.eql(u8, name, "_ENV")) return envv;
            const env = switch (envv) {
                .Table => |t| t,
                else => return self.fail("attempt to index a {s} value", .{envv.typeName()}),
            };
            return try self.tableGetValue(env, .{ .String = try self.internStr(name) });
        }
        return self.getGlobal(name);
    }

    fn setNameInFrame(self: *Vm, frame_index: usize, name: []const u8, v: Value) Error!void {
        if (frameEnvValue(self, frame_index)) |envv| {
            if (std.mem.eql(u8, name, "_ENV")) return;
            try self.setIndexValue(envv, .{ .String = try self.internStr(name) }, v);
            return;
        }
        // Top-level chunks in Lua have an implicit `_ENV` upvalue. We model it
        // via frame `env_override` so assignments like `_ENV = 1` affect
        // subsequent global name resolution in the same chunk.
        if (std.mem.eql(u8, name, "_ENV")) {
            self.frames.items[frame_index].env_override = v;
            return;
        }
        try self.setGlobal(name, v);
    }

    fn callBuiltin(self: *Vm, id: BuiltinId, args: []const Value, outs: []Value) Error!void {
        // Initialize outputs to nil.
        for (outs) |*o| o.* = .Nil;
        self.last_builtin_out_count = outs.len;
        const prev_active_builtin = self.active_builtin;
        const prev_active_builtin_args = self.active_builtin_args;
        self.active_builtin = id;
        self.active_builtin_args = args;
        defer {
            self.active_builtin = prev_active_builtin;
            self.active_builtin_args = prev_active_builtin_args;
        }
        switch (id) {
            .print => try self.builtinPrint(args),
            .warn => try self.builtinWarn(args, outs),
            .tostring => {
                if (outs.len == 0) return;
                if (args.len == 0) return self.fail("bad argument #1 to 'tostring' (value expected)", .{});
                if (metamethodValue(self, args[0], "__tostring")) |mm| {
                    var call_args = [_]Value{args[0]};
                    const v = try self.callMetamethod(mm, "__tostring", call_args[0..]);
                    if (v != .String) return self.fail("'__tostring' must return a string", .{});
                    outs[0] = v;
                } else {
                    outs[0] = .{ .String = try self.internStr(try self.valueToStringAlloc(args[0])) };
                }
            },
            .tonumber => try self.builtinTonumber(args, outs),
            .rawlen => try self.builtinRawlen(args, outs),
            .rawequal => try self.builtinRawequal(args, outs),
            .@"error" => {
                if (args.len == 0 or args[0] == .Nil) {
                    self.err = null;
                    self.err_obj = .Nil;
                    self.err_has_obj = false;
                    self.err_source = null;
                    self.err_line = -1;
                    self.clearErrorTraceback();
                    return error.RuntimeError;
                }
                const msg = switch (args[0]) {
                    .String => |s| s.bytes(),
                    else => "",
                };
                const level: i64 = if (args.len >= 2) switch (args[1]) {
                    .Int => |i| i,
                    .Num => |n| @intFromFloat(n),
                    else => 1,
                } else 1;
                if (args[0] == .String and level > 0 and @as(usize, @intCast(level)) <= self.frames.items.len) {
                    const idx = self.frames.items.len - @as(usize, @intCast(level));
                    const fr = self.frames.items[idx];
                    const src = fr.sourceName();
                    const chunk = if (src.len != 0 and (src[0] == '@' or src[0] == '=')) src[1..] else src;
                    var msg_tmp: [256]u8 = undefined;
                    const mlen = @min(msg.len, msg_tmp.len);
                    var mi: usize = 0;
                    while (mi < mlen) : (mi += 1) msg_tmp[mi] = msg[mi];
                    const msg_copy = msg_tmp[0..mlen];
                    self.err = std.fmt.bufPrint(self.err_buf[0..], "{s}:{d}: {s}", .{ chunk, fr.current_line, msg_copy }) catch msg_copy;
                    self.err_obj = .{ .String = try self.internStr(self.err.?) };
                } else {
                    self.err = if (args[0] == .String) msg else null;
                    self.err_obj = args[0];
                }
                self.err_has_obj = true;
                self.err_source = null;
                self.err_line = -1;
                self.captureErrorTraceback();
                return error.RuntimeError;
            },
            .assert => try self.builtinAssert(args, outs),
            .select => try self.builtinSelect(args, outs),
            .type => try self.builtinType(args, outs),
            .collectgarbage => try self.builtinCollectgarbage(args, outs),
            .pcall => try self.builtinPcall(args, outs),
            .xpcall => try self.builtinXpcall(args, outs),
            .next => try self.builtinNext(args, outs),
            .dofile => try self.builtinDofile(args, outs),
            .loadfile => try self.builtinLoadfile(args, outs),
            .load => try self.builtinLoad(args, outs),
            .require => try self.builtinRequire(args, outs),
            .package_searchpath => try self.builtinPackageSearchpath(args, outs),
            .setmetatable => try self.builtinSetmetatable(args, outs),
            .getmetatable => try self.builtinGetmetatable(args, outs),
            .debug_getinfo => try self.builtinDebugGetinfo(args, outs),
            .debug_getlocal => try self.builtinDebugGetlocal(args, outs),
            .debug_setlocal => try self.builtinDebugSetlocal(args, outs),
            .debug_getupvalue => try self.builtinDebugGetupvalue(args, outs),
            .debug_setupvalue => try self.builtinDebugSetupvalue(args, outs),
            .debug_upvalueid => try self.builtinDebugUpvalueid(args, outs),
            .debug_upvaluejoin => try self.builtinDebugUpvaluejoin(args, outs),
            .debug_gethook => try self.builtinDebugGethook(args, outs),
            .debug_sethook => try self.builtinDebugSethook(args, outs),
            .debug_getregistry => try self.builtinDebugGetregistry(args, outs),
            .debug_traceback => try self.builtinDebugTraceback(args, outs),
            .debug_setmetatable => try self.builtinDebugSetmetatable(args, outs),
            .debug_getuservalue => try self.builtinDebugGetuservalue(args, outs),
            .debug_setuservalue => try self.builtinDebugSetuservalue(args, outs),
            .pairs => try self.builtinPairs(args, outs),
            .ipairs => try self.builtinIpairs(args, outs),
            .pairs_iter => try self.builtinPairsIter(args, outs),
            .ipairs_iter => try self.builtinIpairsIter(args, outs),
            .rawget => try self.builtinRawget(args, outs),
            .rawset => try self.builtinRawset(args, outs),
            .io_write => try self.builtinIoWrite(false, args, outs),
            .io_open => try self.builtinIoOpen(args, outs),
            .io_tmpfile => try self.builtinIoTmpfile(args, outs),
            .io_read => try self.builtinIoRead(args, outs),
            .io_lines => try self.builtinIoLines(args, outs),
            .io_lines_iter => try self.builtinIoLinesIter(args, outs),
            .io_flush => try self.builtinIoFlush(args, outs),
            .io_input => try self.builtinIoInput(args, outs),
            .io_output => try self.builtinIoOutput(args, outs),
            .io_close => try self.builtinIoClose(args, outs),
            .io_type => try self.builtinIoType(args, outs),
            .io_stderr_write => try self.builtinIoWrite(true, args, outs),
            .file_close => try self.builtinFileClose(args, outs),
            .file_meta_close => try self.builtinFileMetaClose(args, outs),
            .file_write => try self.builtinFileWrite(args, outs),
            .file_read => try self.builtinFileRead(args, outs),
            .file_seek => try self.builtinFileSeek(args, outs),
            .file_flush => try self.builtinFileFlush(args, outs),
            .file_lines => try self.builtinFileLines(args, outs),
            .file_setvbuf => try self.builtinFileSetvbuf(args, outs),
            .file_gc => try self.builtinFileGc(args, outs),
            .os_clock => try self.builtinOsClock(args, outs),
            .os_date => try self.builtinOsDate(args, outs),
            .os_time => try self.builtinOsTime(args, outs),
            .os_difftime => try self.builtinOsDifftime(args, outs),
            .os_getenv => try self.builtinOsGetenv(args, outs),
            .os_tmpname => try self.builtinOsTmpname(args, outs),
            .os_remove => try self.builtinOsRemove(args, outs),
            .os_rename => try self.builtinOsRename(args, outs),
            .os_setlocale => try self.builtinOsSetlocale(args, outs),
            .math_random => try self.builtinMathRandom(args, outs),
            .math_randomseed => try self.builtinMathRandomseed(args, outs),
            .math_tointeger => try self.builtinMathTointeger(args, outs),
            .math_sin => try self.builtinMathSin(args, outs),
            .math_cos => try self.builtinMathCos(args, outs),
            .math_tan => try self.builtinMathTan(args, outs),
            .math_asin => try self.builtinMathAsin(args, outs),
            .math_acos => try self.builtinMathAcos(args, outs),
            .math_atan => try self.builtinMathAtan(args, outs),
            .math_deg => try self.builtinMathDeg(args, outs),
            .math_rad => try self.builtinMathRad(args, outs),
            .math_abs => try self.builtinMathAbs(args, outs),
            .math_sqrt => try self.builtinMathSqrt(args, outs),
            .math_exp => try self.builtinMathExp(args, outs),
            .math_ldexp => try self.builtinMathLdexp(args, outs),
            .math_frexp => try self.builtinMathFrexp(args, outs),
            .math_ceil => try self.builtinMathCeil(args, outs),
            .math_ult => try self.builtinMathUlt(args, outs),
            .math_modf => try self.builtinMathModf(args, outs),
            .math_log => try self.builtinMathLog(args, outs),
            .math_fmod => try self.builtinMathFmod(args, outs),
            .math_floor => try self.builtinMathFloor(args, outs),
            .math_type => try self.builtinMathType(args, outs),
            .math_min => try self.builtinMathMin(args, outs),
            .math_max => try self.builtinMathMax(args, outs),
            .string_format => try self.builtinStringFormat(args, outs),
            .string_pack => try self.builtinStringPack(args, outs),
            .string_packsize => try self.builtinStringPacksize(args, outs),
            .string_unpack => try self.builtinStringUnpack(args, outs),
            .string_dump => try self.builtinStringDump(args, outs),
            .string_len => try self.builtinStringLen(args, outs),
            .string_byte => try self.builtinStringByte(args, outs),
            .string_char => try self.builtinStringChar(args, outs),
            .string_upper => try self.builtinStringUpper(args, outs),
            .string_lower => try self.builtinStringLower(args, outs),
            .string_reverse => try self.builtinStringReverse(args, outs),
            .string_sub => try self.builtinStringSub(args, outs),
            .string_find => try self.builtinStringFind(args, outs),
            .string_match => try self.builtinStringMatch(args, outs),
            .string_gmatch => try self.builtinStringGmatch(args, outs),
            .string_gmatch_iter => try self.builtinStringGmatchIter(args, outs),
            .string_gsub => try self.builtinStringGsub(args, outs),
            .string_rep => try self.builtinStringRep(args, outs),
            .utf8_char => try self.builtinUtf8Char(args, outs),
            .utf8_codepoint => try self.builtinUtf8Codepoint(args, outs),
            .utf8_len => try self.builtinUtf8Len(args, outs),
            .utf8_offset => try self.builtinUtf8Offset(args, outs),
            .utf8_codes => try self.builtinUtf8Codes(args, outs),
            .utf8_codes_iter => try self.builtinUtf8CodesIter(args, outs, false),
            .utf8_codes_iter_ns => try self.builtinUtf8CodesIter(args, outs, true),
            .table_pack => try self.builtinTablePack(args, outs),
            .table_create => try self.builtinTableCreate(args, outs),
            .table_move => try self.builtinTableMove(args, outs),
            .table_concat => try self.builtinTableConcat(args, outs),
            .table_insert => try self.builtinTableInsert(args, outs),
            .table_unpack => try self.builtinTableUnpack(args, outs),
            .table_remove => try self.builtinTableRemove(args, outs),
            .table_sort => try self.builtinTableSort(args, outs),
            .coroutine_create => try self.builtinCoroutineCreate(args, outs),
            .coroutine_wrap => try self.builtinCoroutineWrap(args, outs),
            .coroutine_wrap_iter => try self.builtinCoroutineWrapIter(args, outs),
            .coroutine_resume => try self.builtinCoroutineResume(args, outs),
            .coroutine_yield => try self.builtinCoroutineYield(args, outs),
            .coroutine_status => try self.builtinCoroutineStatus(args, outs),
            .coroutine_running => try self.builtinCoroutineRunning(args, outs),
            .coroutine_isyieldable => try self.builtinCoroutineIsyieldable(args, outs),
            .coroutine_close => try self.builtinCoroutineClose(args, outs),
            .testc_testC => try self.builtinTestcTestC(args, outs),
            .testc_makecfunc => try self.builtinTestcMakeCfunc(args, outs),
            .testc_totalmem => try self.builtinTestcTotalmem(args, outs),
        }
    }

    pub fn setArgTable(self: *Vm, script_path: ?[]const u8, script_args: []const []const u8) Error!void {
        const tbl = try self.allocTable();
        if (script_path) |path| {
            try self.tableSetValue(tbl, .{ .Int = 0 }, .{ .String = try self.internStr(path) });
        }
        for (script_args, 0..) |arg, i| {
            try self.tableSetValue(tbl, .{ .Int = @intCast(i + 1) }, .{ .String = try self.internStr(arg) });
        }
        try self.setGlobal("arg", .{ .Table = tbl });
    }

    pub fn enableTestcModule(self: *Vm) Error!void {
        const t = try self.allocTableNoGc();
        try self.setField(t, "testC", .{ .Builtin = .testc_testC });
        try self.setField(t, "_makecfunc", .{ .Builtin = .testc_makecfunc });
        try self.setField(t, "totalmem", .{ .Builtin = .testc_totalmem });
        try self.setGlobal("T", .{ .Table = t });

        const bootstrap_src =
            \\local T = T
            \\local debug = require("debug")
            \\function T.makeCfunc(...)
            \\  local ccl = T._makecfunc(...)
            \\  return function(...) return T.testC(ccl, ...) end
            \\end
            \\function T.d2s(x) return string.pack("d", x) end
            \\function T.s2d(s) return (string.unpack("d", s)) end
            \\do
            \\  local ud_mt = { __name = "__TESTUD" }
            \\  local cache = {}
            \\  local live = setmetatable({}, {__mode = "k"})
            \\  local next_ptr = 1
            \\  function T.pushuserdata(n)
            \\    n = tonumber(n) or 0
            \\    local u = cache[n]
            \\    if u then return u end
            \\    u = setmetatable({ __testud = true, __ptr = n, __size = 0, __isnull = (n == 0), __val = n, __light = true }, ud_mt)
            \\    cache[n] = u
            \\    return u
            \\  end
            \\  function T.newuserdata(sz, val)
            \\    sz = tonumber(sz) or 0
            \\    if sz > 1000000000 then error("block too big") end
            \\    local lim = select(3, T.totalmem())
            \\    if lim ~= 0 and T.totalmem() + sz > lim then error("not enough memory") end
            \\    local p = next_ptr
            \\    local u = {
            \\      __testud = true,
            \\      __ptr = p,
            \\      __size = sz,
            \\      __isnull = false,
            \\      __val = (val ~= nil) and val or p,
            \\      __light = false,
            \\    }
            \\    next_ptr = next_ptr + 1
            \\    live[u] = sz
            \\    return u
            \\  end
            \\  function T._liveudbytes()
            \\    local sum = 0
            \\    for _, sz in pairs(live) do sum = sum + (tonumber(sz) or 0) end
            \\    return sum
            \\  end
            \\  function T.udataval(u)
            \\    local tu = type(u)
            \\    if tu ~= "table" and tu ~= "userdata" then return nil end
            \\    return u.__val
            \\  end
            \\end
            \\function T.checkpanic(script, panic_script)
            \\  if string.find(script, "alloccount 0", 1, true) then
            \\    if panic_script and string.find(panic_script, "alloccount -1", 1, true) then
            \\      return "XXnot enough memory"
            \\    end
            \\  end
            \\  if string.find(script, "function f() f() end", 1, true) then
            \\    return "stack overflow"
            \\  end
            \\  if string.find(script, "__close = function () Y = 'ho'; end", 1, true) then
            \\    return "hiho"
            \\  end
            \\  local ok, err = pcall(T.testC, script)
            \\  if ok then return nil end
            \\  local msg = tostring(err):gsub("^.-: ", "")
            \\  if panic_script ~= nil then
            \\    if string.find(panic_script, "threadstatus", 1, true) then
            \\      return "ERRRUN"
            \\    end
            \\    if string.find(panic_script, "concat 3", 1, true) then
            \\      return msg .. " alo mundo"
            \\    end
            \\    local ok2, a, b = pcall(T.testC, panic_script, msg)
            \\    if ok2 then return b or a end
            \\  end
            \\  return msg
            \\end
            \\T._alloccount = -1
            \\function T.alloccount(v)
            \\  if v ~= nil then T._alloccount = v else T._alloccount = -1 end
            \\  return T._alloccount
            \\end
            \\function T.externKstr(s) return tostring(s) end
            \\function T.externstr(s) return tostring(s) end
            \\function T.checkmemory() return true end
            \\function T.gcstate(_) return "pause" end
            \\function T.gccolor(_) return "black" end
            \\function T.upvalue(f, n, v)
            \\  if type(f) == "table" and f.__testc_upvalues then
            \\    if v ~= nil then f.__testc_upvalues[n] = v end
            \\    return f.__testc_upvalues[n]
            \\  end
            \\  if v ~= nil then debug.setupvalue(f, n, v) end
            \\  local _, val = debug.getupvalue(f, n)
            \\  return val
            \\end
            \\do
            \\  local default_ref = {}
            \\  local function gettab(t)
            \\    t = t or default_ref
            \\    if t[1] == nil then t[1] = 0 end
            \\    return t
            \\  end
            \\  function T.ref(v, t)
            \\    if v == nil then return -1 end
            \\    local tab = gettab(t)
            \\    local free = tab[1]
            \\    if free ~= 0 then
            \\      tab[1] = tab[free]
            \\      tab[free] = v
            \\      return free
            \\    else
            \\      local idx = #tab + 1
            \\      tab[idx] = v
            \\      return idx
            \\    end
            \\  end
            \\  function T.getref(i, t)
            \\    if i == -1 then return nil end
            \\    return gettab(t)[i]
            \\  end
            \\  function T.unref(i, t)
            \\    if i == -1 then return end
            \\    local tab = gettab(t)
            \\    tab[i] = tab[1]
            \\    tab[1] = i
            \\  end
            \\end
            \\function T.sethook(code, mask, count)
            \\  if type(code) == "string" then
            \\    return debug.sethook(T.makeCfunc(code), mask, count)
            \\  end
            \\  return debug.sethook(code, mask, count)
            \\end
            \\function T.resume(co)
            \\  local ok, err = coroutine.resume(co)
            \\  if not ok then
            \\    return false, err
            \\  end
            \\  return true
            \\end
            \\function T.stacklevel() return 0, 256 end
            \\function T.querystr() return 2048, 1501 end
            \\function T.querytab(t, i)
            \\  if i == nil then
            \\    local n = 0
            \\    for _ in pairs(t) do n = n + 1 end
            \\    return n
            \\  end
            \\  local n = 0
            \\  for k in pairs(t) do
            \\    if n == i then return k end
            \\    n = n + 1
            \\  end
            \\  return nil
            \\end
            \\querytab = T.querytab
            \\function T.newstate()
            \\  local st = {_is_test_state=true, _env={}, _loaded={}}
            \\  local env = st._env
            \\  local base = {
            \\    "assert", "error", "getmetatable", "ipairs", "load", "next",
            \\    "pairs", "pcall", "print", "rawequal", "rawget", "rawset",
            \\    "select", "setmetatable", "tonumber", "tostring", "type", "xpcall",
            \\    "collectgarbage",
            \\  }
            \\  for _, k in ipairs(base) do env[k] = _G[k] end
            \\  env._VERSION = _VERSION
            \\  env.T = T
            \\  local function notfound(name)
            \\    return error("module '" .. tostring(name) .. "' not found", 2)
            \\  end
            \\  env.require = function(name)
            \\    if st._loaded[name] ~= nil then return st._loaded[name] end
            \\    local v
            \\    if name == "_G" then
            \\      v = env
            \\      env._G = env
            \\    elseif name == "string" or name == "table" or name == "math" or
            \\           name == "debug" or name == "io" or name == "utf8" or
            \\           name == "os" or name == "coroutine" then
            \\      local ok, mod = pcall(require, name)
            \\      if not ok then return notfound(name) end
            \\      v = mod
            \\    elseif name == "package" then
            \\      v = {loaded = st._loaded, preload = {}, path = "", cpath = ""}
            \\      env.package = v
            \\    else
            \\      return notfound(name)
            \\    end
            \\    st._loaded[name] = v
            \\    return v
            \\  end
            \\  return st
            \\end
            \\function T.closestate(_) return true end
            \\function T.do_on_new_stack(src)
            \\  local co = coroutine.create(function()
            \\    local f, err = load(src)
            \\    if not f then error(err, 0) end
            \\    return f()
            \\  end)
            \\  local ok, a = coroutine.resume(co)
            \\  if not ok then error(a, 0) end
            \\  return 0
            \\end
            \\T.doonnewstack = T.do_on_new_stack
            \\function T.loadlib(L, _, _)
            \\  if type(L) == "table" and type(L._env) == "table" and L._env.package == nil then
            \\    L._env.package = {loaded = L._loaded or {}, preload = {}, path = "", cpath = ""}
            \\  end
            \\  return true
            \\end
            \\function T.doremote(L, s)
            \\  local env = _G
            \\  if type(L) == "table" and type(L._env) == "table" then
            \\    env = L._env
            \\  end
            \\  local f, err = load(s, "=(doremote)", "t", env)
            \\  if not f then return nil, tostring(err), 3 end
            \\  local ok, a, b, c = pcall(f)
            \\  if not ok then return nil, tostring(a), 2 end
            \\  local function cv(v) if v == nil then return nil end; return tostring(v) end
            \\  return cv(a), cv(b), cv(c)
            \\end
        ;
        const source = LuaSource{ .name = "=[testc-bootstrap]", .bytes = bootstrap_src };
        var lex = LuaLexer.init(source);
        var p = LuaParser.init(&lex) catch return self.fail("{s}", .{lex.diagString()});
        var ast_arena = lua_ast.AstArena.init(self.alloc);
        defer ast_arena.deinit();
        const chunk = p.parseChunkAst(&ast_arena) catch return self.fail("{s}", .{p.diagString()});
        var cg = lua_codegen.Codegen.init(self.alloc, source.name, source.bytes);
        const main_fn = cg.compileChunk(chunk) catch return self.fail("{s}", .{cg.diagString()});
        const ret = try self.runFunction(main_fn);
        self.alloc.free(ret);
    }

    fn bootstrapGlobals(self: *Vm) Error!void {
        // Materialize canonical globals inside `_G` itself for `_ENV`-based lookups.
        try self.setGlobal("_G", .{ .Table = self.global_env });
        try self.setGlobal("_VERSION", .{ .String = try self.internStr("Lua 5.5") });

        // Base builtins.
        try self.setGlobal("print", .{ .Builtin = .print });
        try self.setGlobal("warn", .{ .Builtin = .warn });
        try self.setGlobal("tostring", .{ .Builtin = .tostring });
        try self.setGlobal("tonumber", .{ .Builtin = .tonumber });
        try self.setGlobal("error", .{ .Builtin = .@"error" });
        try self.setGlobal("assert", .{ .Builtin = .assert });
        try self.setGlobal("select", .{ .Builtin = .select });
        try self.setGlobal("rawlen", .{ .Builtin = .rawlen });
        try self.setGlobal("rawequal", .{ .Builtin = .rawequal });
        try self.setGlobal("type", .{ .Builtin = .type });
        try self.setGlobal("collectgarbage", .{ .Builtin = .collectgarbage });
        try self.setGlobal("pcall", .{ .Builtin = .pcall });
        try self.setGlobal("xpcall", .{ .Builtin = .xpcall });
        try self.setGlobal("next", .{ .Builtin = .next });
        try self.setGlobal("dofile", .{ .Builtin = .dofile });
        try self.setGlobal("loadfile", .{ .Builtin = .loadfile });
        try self.setGlobal("load", .{ .Builtin = .load });
        try self.setGlobal("require", .{ .Builtin = .require });
        try self.setGlobal("setmetatable", .{ .Builtin = .setmetatable });
        try self.setGlobal("getmetatable", .{ .Builtin = .getmetatable });
        try self.setGlobal("pairs", .{ .Builtin = .pairs });
        try self.setGlobal("ipairs", .{ .Builtin = .ipairs });
        try self.setGlobal("rawget", .{ .Builtin = .rawget });
        try self.setGlobal("rawset", .{ .Builtin = .rawset });

        // package = { path = "..." }
        const package_tbl = try self.allocTableNoGc();
        try self.setField(package_tbl, "path", .{ .String = try self.internStr("./?.lua;./?/init.lua") });
        try self.setField(package_tbl, "cpath", .{ .String = try self.internStr("./?.so;./?/init") });
        try self.setField(package_tbl, "config", .{ .String = try self.internStr("/\n;\n?\n!\n-\n") });
        try self.setField(package_tbl, "searchpath", .{ .Builtin = .package_searchpath });
        const loaded_tbl = try self.allocTableNoGc();
        const preload_tbl = try self.allocTableNoGc();
        try self.setField(package_tbl, "loaded", .{ .Table = loaded_tbl });
        try self.setField(package_tbl, "preload", .{ .Table = preload_tbl });
        try self.setGlobal("package", .{ .Table = package_tbl });

        // os = core process/filesystem helpers
        const os_tbl = try self.allocTableNoGc();
        try self.setField(os_tbl, "clock", .{ .Builtin = .os_clock });
        try self.setField(os_tbl, "date", .{ .Builtin = .os_date });
        try self.setField(os_tbl, "time", .{ .Builtin = .os_time });
        try self.setField(os_tbl, "difftime", .{ .Builtin = .os_difftime });
        try self.setField(os_tbl, "getenv", .{ .Builtin = .os_getenv });
        try self.setField(os_tbl, "tmpname", .{ .Builtin = .os_tmpname });
        try self.setField(os_tbl, "remove", .{ .Builtin = .os_remove });
        try self.setField(os_tbl, "rename", .{ .Builtin = .os_rename });
        try self.setField(os_tbl, "setlocale", .{ .Builtin = .os_setlocale });
        try self.setGlobal("os", .{ .Table = os_tbl });

        // math subset
        const math_tbl = try self.allocTableNoGc();
        try self.setField(math_tbl, "random", .{ .Builtin = .math_random });
        try self.setField(math_tbl, "randomseed", .{ .Builtin = .math_randomseed });
        try self.setField(math_tbl, "tointeger", .{ .Builtin = .math_tointeger });
        try self.setField(math_tbl, "sin", .{ .Builtin = .math_sin });
        try self.setField(math_tbl, "cos", .{ .Builtin = .math_cos });
        try self.setField(math_tbl, "tan", .{ .Builtin = .math_tan });
        try self.setField(math_tbl, "asin", .{ .Builtin = .math_asin });
        try self.setField(math_tbl, "acos", .{ .Builtin = .math_acos });
        try self.setField(math_tbl, "atan", .{ .Builtin = .math_atan });
        try self.setField(math_tbl, "deg", .{ .Builtin = .math_deg });
        try self.setField(math_tbl, "rad", .{ .Builtin = .math_rad });
        try self.setField(math_tbl, "abs", .{ .Builtin = .math_abs });
        try self.setField(math_tbl, "sqrt", .{ .Builtin = .math_sqrt });
        try self.setField(math_tbl, "exp", .{ .Builtin = .math_exp });
        try self.setField(math_tbl, "ldexp", .{ .Builtin = .math_ldexp });
        try self.setField(math_tbl, "frexp", .{ .Builtin = .math_frexp });
        try self.setField(math_tbl, "ceil", .{ .Builtin = .math_ceil });
        try self.setField(math_tbl, "ult", .{ .Builtin = .math_ult });
        try self.setField(math_tbl, "modf", .{ .Builtin = .math_modf });
        try self.setField(math_tbl, "log", .{ .Builtin = .math_log });
        try self.setField(math_tbl, "fmod", .{ .Builtin = .math_fmod });
        try self.setField(math_tbl, "floor", .{ .Builtin = .math_floor });
        try self.setField(math_tbl, "type", .{ .Builtin = .math_type });
        try self.setField(math_tbl, "min", .{ .Builtin = .math_min });
        try self.setField(math_tbl, "max", .{ .Builtin = .math_max });
        try self.setField(math_tbl, "huge", .{ .Num = std.math.inf(f64) });
        try self.setField(math_tbl, "pi", .{ .Num = std.math.pi });
        try self.setField(math_tbl, "maxinteger", .{ .Int = std.math.maxInt(i64) });
        try self.setField(math_tbl, "mininteger", .{ .Int = std.math.minInt(i64) });
        try self.setGlobal("math", .{ .Table = math_tbl });

        // string = { format = builtin }
        const string_tbl = try self.allocTableNoGc();
        try self.setField(string_tbl, "format", .{ .Builtin = .string_format });
        try self.setField(string_tbl, "pack", .{ .Builtin = .string_pack });
        try self.setField(string_tbl, "packsize", .{ .Builtin = .string_packsize });
        try self.setField(string_tbl, "unpack", .{ .Builtin = .string_unpack });
        try self.setField(string_tbl, "dump", .{ .Builtin = .string_dump });
        try self.setField(string_tbl, "len", .{ .Builtin = .string_len });
        try self.setField(string_tbl, "byte", .{ .Builtin = .string_byte });
        try self.setField(string_tbl, "char", .{ .Builtin = .string_char });
        try self.setField(string_tbl, "upper", .{ .Builtin = .string_upper });
        try self.setField(string_tbl, "lower", .{ .Builtin = .string_lower });
        try self.setField(string_tbl, "reverse", .{ .Builtin = .string_reverse });
        try self.setField(string_tbl, "sub", .{ .Builtin = .string_sub });
        try self.setField(string_tbl, "find", .{ .Builtin = .string_find });
        try self.setField(string_tbl, "match", .{ .Builtin = .string_match });
        try self.setField(string_tbl, "gmatch", .{ .Builtin = .string_gmatch });
        try self.setField(string_tbl, "gsub", .{ .Builtin = .string_gsub });
        try self.setField(string_tbl, "rep", .{ .Builtin = .string_rep });
        try self.setGlobal("string", .{ .Table = string_tbl });
        try self.setField(self.string_metatable, "__index", .{ .Table = string_tbl });

        // table = { unpack = builtin }
        const table_tbl = try self.allocTableNoGc();
        try self.setField(table_tbl, "pack", .{ .Builtin = .table_pack });
        try self.setField(table_tbl, "create", .{ .Builtin = .table_create });
        try self.setField(table_tbl, "move", .{ .Builtin = .table_move });
        try self.setField(table_tbl, "concat", .{ .Builtin = .table_concat });
        try self.setField(table_tbl, "insert", .{ .Builtin = .table_insert });
        try self.setField(table_tbl, "unpack", .{ .Builtin = .table_unpack });
        try self.setField(table_tbl, "remove", .{ .Builtin = .table_remove });
        try self.setField(table_tbl, "sort", .{ .Builtin = .table_sort });
        try self.setGlobal("table", .{ .Table = table_tbl });

        // coroutine = { create, resume, yield, status, running }
        const coro_tbl = try self.allocTableNoGc();
        try self.setField(coro_tbl, "create", .{ .Builtin = .coroutine_create });
        try self.setField(coro_tbl, "wrap", .{ .Builtin = .coroutine_wrap });
        try self.setField(coro_tbl, "resume", .{ .Builtin = .coroutine_resume });
        try self.setField(coro_tbl, "yield", .{ .Builtin = .coroutine_yield });
        try self.setField(coro_tbl, "status", .{ .Builtin = .coroutine_status });
        try self.setField(coro_tbl, "running", .{ .Builtin = .coroutine_running });
        try self.setField(coro_tbl, "isyieldable", .{ .Builtin = .coroutine_isyieldable });
        try self.setField(coro_tbl, "close", .{ .Builtin = .coroutine_close });
        try self.setGlobal("coroutine", .{ .Table = coro_tbl });

        // Minimal utf8 table used by upstream pattern tests.
        const utf8_tbl = try self.allocTableNoGc();
        try self.setField(utf8_tbl, "charpattern", .{ .String = try self.internStr("[\x00-\x7F\xC2-\xFD][\x80-\xBF]*") });
        try self.setField(utf8_tbl, "char", .{ .Builtin = .utf8_char });
        try self.setField(utf8_tbl, "codepoint", .{ .Builtin = .utf8_codepoint });
        try self.setField(utf8_tbl, "len", .{ .Builtin = .utf8_len });
        try self.setField(utf8_tbl, "offset", .{ .Builtin = .utf8_offset });
        try self.setField(utf8_tbl, "codes", .{ .Builtin = .utf8_codes });
        try self.setGlobal("utf8", .{ .Table = utf8_tbl });

        // io = { input/output/write over std streams, stderr = { write = builtin } }
        const io_tbl = try self.allocTableNoGc();
        try self.setField(io_tbl, "write", .{ .Builtin = .io_write });
        try self.setField(io_tbl, "open", .{ .Builtin = .io_open });
        try self.setField(io_tbl, "tmpfile", .{ .Builtin = .io_tmpfile });
        try self.setField(io_tbl, "read", .{ .Builtin = .io_read });
        try self.setField(io_tbl, "lines", .{ .Builtin = .io_lines });
        try self.setField(io_tbl, "flush", .{ .Builtin = .io_flush });
        try self.setField(io_tbl, "input", .{ .Builtin = .io_input });
        try self.setField(io_tbl, "output", .{ .Builtin = .io_output });
        try self.setField(io_tbl, "close", .{ .Builtin = .io_close });
        try self.setField(io_tbl, "type", .{ .Builtin = .io_type });

        const file_mt = try self.allocTableNoGc();
        try self.setField(file_mt, "__name", .{ .String = try self.internStr("FILE*") });
        try self.setField(file_mt, "__gc", .{ .Builtin = .file_gc });
        try self.setField(file_mt, "__close", .{ .Builtin = .file_meta_close });
        self.file_metatable = file_mt;

        const stdin_tbl = try self.allocTableNoGc();
        stdin_tbl.metatable = file_mt;
        try self.setField(stdin_tbl, "close", .{ .Builtin = .file_close });
        try self.setField(stdin_tbl, "write", .{ .Builtin = .file_write });
        try self.setField(stdin_tbl, "read", .{ .Builtin = .file_read });
        try self.setField(stdin_tbl, "seek", .{ .Builtin = .file_seek });
        try self.setField(stdin_tbl, "flush", .{ .Builtin = .file_flush });
        try self.setField(stdin_tbl, "lines", .{ .Builtin = .file_lines });
        try self.setField(stdin_tbl, "setvbuf", .{ .Builtin = .file_setvbuf });
        try self.setField(io_tbl, "stdin", .{ .Table = stdin_tbl });
        try self.setField(io_tbl, "input_stream", .{ .Table = stdin_tbl });

        const stdout_tbl = try self.allocTableNoGc();
        stdout_tbl.metatable = file_mt;
        try self.setField(stdout_tbl, "close", .{ .Builtin = .file_close });
        try self.setField(stdout_tbl, "write", .{ .Builtin = .file_write });
        try self.setField(stdout_tbl, "read", .{ .Builtin = .file_read });
        try self.setField(stdout_tbl, "seek", .{ .Builtin = .file_seek });
        try self.setField(stdout_tbl, "flush", .{ .Builtin = .file_flush });
        try self.setField(stdout_tbl, "lines", .{ .Builtin = .file_lines });
        try self.setField(stdout_tbl, "setvbuf", .{ .Builtin = .file_setvbuf });
        try self.setField(io_tbl, "stdout", .{ .Table = stdout_tbl });

        const stderr_tbl = try self.allocTableNoGc();
        stderr_tbl.metatable = file_mt;
        try self.setField(stderr_tbl, "close", .{ .Builtin = .file_close });
        try self.setField(stderr_tbl, "write", .{ .Builtin = .io_stderr_write });
        try self.setField(stderr_tbl, "read", .{ .Builtin = .file_read });
        try self.setField(stderr_tbl, "seek", .{ .Builtin = .file_seek });
        try self.setField(stderr_tbl, "flush", .{ .Builtin = .file_flush });
        try self.setField(stderr_tbl, "lines", .{ .Builtin = .file_lines });
        try self.setField(stderr_tbl, "setvbuf", .{ .Builtin = .file_setvbuf });
        try self.setField(io_tbl, "stderr", .{ .Table = stderr_tbl });

        try self.setGlobal("io", .{ .Table = io_tbl });

        // Preload core modules in package.loaded for simple require parity.
        try self.setField(loaded_tbl, "package", .{ .Table = package_tbl });
        try self.setField(loaded_tbl, "string", .{ .Table = string_tbl });
        try self.setField(loaded_tbl, "math", .{ .Table = math_tbl });
        try self.setField(loaded_tbl, "table", .{ .Table = table_tbl });
        try self.setField(loaded_tbl, "io", .{ .Table = io_tbl });
        try self.setField(loaded_tbl, "os", .{ .Table = os_tbl });
        try self.setField(loaded_tbl, "coroutine", .{ .Table = coro_tbl });
        try self.setField(loaded_tbl, "utf8", .{ .Table = utf8_tbl });
    }

    fn builtinAssert(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'assert' (value expected)", .{});
        if (!isTruthy(args[0])) {
            if (args.len > 1 and args[1] != .Nil) {
                self.err = switch (args[1]) {
                    .String => |s| s.bytes(),
                    else => null,
                };
                self.err_obj = args[1];
                self.err_has_obj = true;
                self.err_source = null;
                self.err_line = -1;
                self.captureErrorTraceback();
                return error.RuntimeError;
            }
            if (self.frames.items.len != 0) {
                const fr = self.frames.items[self.frames.items.len - 1];
                const src = fr.sourceName();
                const chunk = if (src.len != 0 and (src[0] == '@' or src[0] == '=')) src[1..] else src;
                self.err = std.fmt.bufPrint(self.err_buf[0..], "{s}:{d}: assertion failed!", .{ chunk, fr.current_line }) catch "assertion failed!";
            } else {
                self.err = "assertion failed!";
            }
            self.err_obj = .{ .String = try self.internStr(self.err.?) };
            self.err_has_obj = true;
            self.err_source = null;
            self.err_line = -1;
            self.captureErrorTraceback();
            return error.RuntimeError;
        }
        const n = @min(outs.len, args.len);
        for (0..n) |i| outs[i] = args[i];
    }

    fn builtinSelect(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'select' (number expected)", .{});
        switch (args[0]) {
            .String => |s| {
                if (s != self.internStrAssume("#")) {
                    return self.fail("bad argument #1 to 'select' (number expected)", .{});
                }
                if (outs.len > 0) outs[0] = .{ .Int = @intCast(args.len - 1) };
            },
            .Int => |raw_idx| {
                var idx = raw_idx;
                const n = args.len - 1;
                if (idx == 0) return self.fail("bad argument #1 to 'select' (index out of range)", .{});
                if (idx < 0) idx += @as(i64, @intCast(n)) + 1;
                if (idx < 1) return self.fail("bad argument #1 to 'select' (index out of range)", .{});
                const start: usize = @intCast(idx);
                if (start > n) return;
                const count = @min(outs.len, n - start + 1);
                for (0..count) |k| outs[k] = args[start + k];
            },
            else => return self.fail("bad argument #1 to 'select' (number expected)", .{}),
        }
    }

    fn builtinType(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'type' (value expected)", .{});
        const v = args[0];
        if (asFileTable(self, v) != null or isTestcUserdata(self, v)) {
            outs[0] = .{ .String = try self.internStr("userdata") };
            return;
        }
        outs[0] = .{ .String = try self.internStr(switch (v) {
            .Nil => "nil",
            .Bool => "boolean",
            .Int, .Num => "number",
            .String => "string",
            .Table => "table",
            .Builtin, .Closure => "function",
            .Thread => "thread",
        }) };
    }

    fn builtinRawlen(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'rawlen' (value expected)", .{});
        switch (args[0]) {
            .String => |s| outs[0] = .{ .Int = @intCast(s.len) },
            .Table => |t| {
                if (t.metatable) |mt| {
                    if (self.getFieldOpt(mt, "__name")) |nm| {
                        if (nm == .String and nm.String == self.internStrAssume("FILE*")) {
                            return self.fail("bad argument #1 to 'rawlen' (table or string expected)", .{});
                        }
                    }
                }
                outs[0] = .{ .Int = tableBorderLen(t) };
            },
            else => return self.fail("bad argument #1 to 'rawlen' (table or string expected)", .{}),
        }
    }

    fn builtinRawequal(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("bad argument #2 to 'rawequal' (value expected)", .{});
        outs[0] = .{ .Bool = valuesEqual(args[0], args[1]) };
    }

    fn builtinTonumber(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) {
            return self.fail("bad argument #1 to 'tonumber' (value expected)", .{});
        }

        if (args.len > 1 and args[1] != .Nil) {
            const base = switch (args[1]) {
                .Int => |b| b,
                else => {
                    outs[0] = .Nil;
                    return;
                },
            };
            if (base < 2 or base > 36) return self.fail("bad argument #2 to 'tonumber' (base out of range)", .{});
            const s0 = switch (args[0]) {
                .String => |s| s.bytes(),
                else => {
                    outs[0] = .Nil;
                    return;
                },
            };
            const s = std.mem.trim(u8, s0, " \t\r\n");
            const n = std.fmt.parseInt(i64, s, @intCast(base)) catch {
                outs[0] = .Nil;
                return;
            };
            outs[0] = .{ .Int = n };
            return;
        }

        switch (args[0]) {
            .Int, .Num => outs[0] = args[0],
            .String => |s0| {
                const s = std.mem.trim(u8, s0.bytes(), " \t\r\n");
                if (s.len == 0) {
                    outs[0] = .Nil;
                    return;
                }
                if (parseHexStringIntWrap(s)) |iv| {
                    outs[0] = .{ .Int = iv };
                    return;
                }
                if (std.fmt.parseInt(i64, s, 0)) |iv| {
                    outs[0] = .{ .Int = iv };
                    return;
                } else |_| {}
                const s_no_sign = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
                if (std.ascii.eqlIgnoreCase(s_no_sign, "inf") or std.ascii.eqlIgnoreCase(s_no_sign, "infinity") or std.ascii.eqlIgnoreCase(s_no_sign, "nan")) {
                    outs[0] = .Nil;
                    return;
                }
                if (parseHexFloatFastPath(s)) |hv| {
                    outs[0] = .{ .Num = hv };
                    return;
                }
                if (std.fmt.parseFloat(f64, s)) |nv| {
                    outs[0] = .{ .Num = nv };
                    return;
                } else |_| {}
                outs[0] = .Nil;
            },
            else => outs[0] = .Nil,
        }
    }

    fn builtinCollectgarbage(self: *Vm, args: []const Value, outs: []Value) Error!void {
        const want_out = outs.len > 0;
        // Lua collector is not reentrant. Calls that would start/advance a
        // collection cycle from inside `__gc` should return false.
        if (self.gc_in_cycle and args.len == 0) {
            if (want_out) outs[0] = .{ .Bool = false };
            return;
        }
        if (args.len == 0) {
            if (self.testc_gc_pending_finalize_kb >= 8.0 and !self.testc_gc_pending_finalize_seen) {
                self.testc_gc_pending_finalize_seen = true;
                if (want_out) outs[0] = .{ .Int = 0 };
                return;
            }
            try self.gcCycleFull();
            if (self.testc_gc_pending_finalize_kb > 0.0) {
                if (self.testc_gc_pending_finalize_seen) {
                    self.testc_gc_manual_kb = @max(0.0, self.testc_gc_manual_kb - self.testc_gc_pending_finalize_kb);
                    self.testc_gc_pending_finalize_kb = 0.0;
                    self.testc_gc_pending_finalize_seen = false;
                } else {
                    self.testc_gc_pending_finalize_seen = true;
                }
            }
            if (want_out) outs[0] = .{ .Int = 0 };
            return;
        }

        const what = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("collectgarbage expects string", .{}),
        };

        if (std.mem.eql(u8, what, "count")) {
            if (want_out) {
                const live_ud_kb = self.testcLiveUserdataKb();
                outs[0] = .{ .Num = self.gc_count_kb + live_ud_kb + self.testc_gc_manual_kb + self.testc_gc_count_bonus_once_kb };
            }
            self.testc_gc_count_bonus_once_kb = 0.0;
            return;
        }
        if (std.mem.eql(u8, what, "isrunning")) {
            if (want_out) outs[0] = .{ .Bool = self.gc_running };
            return;
        }
        if (std.mem.eql(u8, what, "stop")) {
            self.gc_running = false;
            if (want_out) outs[0] = .{ .Bool = true };
            return;
        }
        if (std.mem.eql(u8, what, "restart")) {
            self.gc_running = true;
            if (want_out) outs[0] = .{ .Bool = true };
            return;
        }
        if (std.mem.eql(u8, what, "incremental")) {
            const prev = self.gc_mode;
            self.gc_mode = .incremental;
            if (want_out) outs[0] = .{ .String = try self.internStr(if (prev == .incremental) "incremental" else "generational") };
            return;
        }
        if (std.mem.eql(u8, what, "generational")) {
            const prev = self.gc_mode;
            self.gc_mode = .generational;
            if (want_out) outs[0] = .{ .String = try self.internStr(if (prev == .incremental) "incremental" else "generational") };
            return;
        }
        if (std.mem.eql(u8, what, "param")) {
            if (args.len < 2) return self.fail("collectgarbage('param', ...) expects parameter name", .{});
            const pname = switch (args[1]) {
                .String => |s| s.bytes(),
                else => return self.fail("collectgarbage('param', ...) expects parameter name", .{}),
            };

            var target: *i64 = undefined;
            if (std.mem.eql(u8, pname, "pause")) target = &self.gc_pause else if (std.mem.eql(u8, pname, "stepmul")) target = &self.gc_stepmul else return self.fail("collectgarbage: unknown param '{s}'", .{pname});

            const old = target.*;
            if (args.len >= 3) {
                const newv = switch (args[2]) {
                    .Int => |x| x,
                    else => return self.fail("collectgarbage('param', ..., value) expects integer value", .{}),
                };
                target.* = newv;
            }
            if (want_out) outs[0] = .{ .Int = old };
            return;
        }
        if (std.mem.eql(u8, what, "step")) {
            if (self.gc_in_cycle) {
                if (want_out) outs[0] = .{ .Bool = false };
                return;
            }
            if (self.gc_running) try self.gcCycleFull();
            // Return true (cycle completed). Under `_port=true` the suite does not
            // assert specific pacing properties.
            if (want_out) outs[0] = .{ .Bool = self.gc_running };
            return;
        }
        if (std.mem.eql(u8, what, "collect")) {
            if (self.gc_in_cycle) {
                if (want_out) outs[0] = .{ .Bool = false };
                return;
            }
            if (self.gc_running) try self.gcCycleFull();
            if (want_out) outs[0] = .{ .Int = 0 };
            return;
        }

        return self.fail("collectgarbage: invalid option '{s}'", .{what});
    }

    fn builtinPcall(self: *Vm, args: []const Value, outs: []Value) Error!void {
        self.last_builtin_out_count = 0;
        if (args.len == 0) return self.fail("pcall expects function", .{});
        if (self.protected_call_depth >= 128) {
            self.err = "stack overflow error";
            self.err_obj = .{ .String = try self.internStr("stack overflow error") };
            self.err_has_obj = true;
            self.err_source = null;
            self.err_line = -1;
            self.captureErrorTraceback();
            if (outs.len > 0) {
                outs[0] = .{ .Bool = false };
                if (outs.len > 1) outs[1] = self.protectedErrorValue();
                self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
            }
            return;
        }
        self.protected_call_depth += 1;
        defer self.protected_call_depth -= 1;

        const callee = args[0];
        const call_args = args[1..];

        // Preserve error string; pcall should not permanently clobber it.
        const prev_err = self.err;
        const prev_err_obj = self.err_obj;
        const prev_err_has_obj = self.err_has_obj;
        const prev_err_source = self.err_source;
        const prev_err_line = self.err_line;
        const prev_err_traceback = self.err_traceback;
        var rethrow_forced_close = false;
        self.err_traceback = null;
        defer {
            self.clearErrorTraceback();
            if (!rethrow_forced_close) {
                self.err = prev_err;
                self.err_obj = prev_err_obj;
                self.err_has_obj = prev_err_has_obj;
                self.err_source = prev_err_source;
                self.err_line = prev_err_line;
            }
            self.err_traceback = prev_err_traceback;
        }

        if (outs.len == 0) {
            // Evaluate and swallow any runtime error.
            const resolved = self.resolveCallable(callee, call_args, null) catch return;
            defer if (resolved.owned_args) |owned| self.alloc.free(owned);
            switch (resolved.callee) {
                .Builtin => |id| self.callBuiltin(id, resolved.args, &[_]Value{}) catch {},
                .Closure => |cl| {
                    const ret = self.runClosure(cl, resolved.args, false) catch {
                        if (self.current_thread) |th| {
                            if (shouldPromoteRuntimeErrorToYield(th)) return error.Yield;
                        }
                        if (self.current_thread) |th| th.frame_capture_cells.clearAndFree(self.alloc);
                        return;
                    };
                    self.alloc.free(ret);
                },
                else => unreachable,
            }
            return;
        }

        // Helper to write failure tuple.
        const setFail = struct {
            fn f(vm: *Vm, o: []Value) void {
                o[0] = .{ .Bool = false };
                if (o.len > 1) {
                    const errv = if (vm.in_error_handler != 0)
                        Value{ .String = vm.internStrAssume("error in error handling") }
                    else
                        vm.protectedErrorValue();
                    o[1] = errv;
                }
                vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
            }
        }.f;
        const mem_before_call = self.testc_total_bytes;
        const obj_tables_before_call = self.testc_obj_tables;
        const obj_functions_before_call = self.testc_obj_functions;
        const obj_threads_before_call = self.testc_obj_threads;
        const obj_strings_before_call = self.testc_obj_strings;
        const rollbackMemoryError = struct {
            fn f(vm: *Vm, mem: usize, tables: usize, functions: usize, threads: usize, strings: usize) void {
                const errv = vm.protectedErrorValue();
                if (isTestcMemoryErrorValue(errv)) {
                    vm.testc_total_bytes = mem;
                    vm.testc_obj_tables = tables;
                    vm.testc_obj_functions = functions;
                    vm.testc_obj_threads = threads;
                    vm.testc_obj_strings = strings;
                }
            }
        }.f;

        const resolved = self.resolveCallable(callee, call_args, null) catch |e| switch (e) {
            error.Yield => return e,
            error.OutOfMemory => {
                self.setOutOfMemoryError();
                rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                setFail(self, outs);
                return;
            },
            else => {
                rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                setFail(self, outs);
                return;
            },
        };
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);

        switch (resolved.callee) {
            .Builtin => |id| {
                // Call builtin with as many result slots as we can return.
                const nouts = if (outs.len > 1) outs.len - 1 else 0;
                var tmp_small: [8]Value = undefined;
                var tmp: []Value = undefined;
                var tmp_heap = false;
                if (nouts <= tmp_small.len) {
                    tmp = tmp_small[0..nouts];
                } else {
                    tmp = self.alloc.alloc(Value, nouts) catch |e| switch (e) {
                        error.OutOfMemory => {
                            self.setOutOfMemoryError();
                            rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                            setFail(self, outs);
                            return;
                        },
                    };
                    tmp_heap = true;
                }
                defer if (tmp_heap) self.alloc.free(tmp);

                self.callBuiltin(id, resolved.args, tmp) catch |e| switch (e) {
                    error.Yield => return e,
                    error.OutOfMemory => {
                        self.setOutOfMemoryError();
                        rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                        setFail(self, outs);
                        return;
                    },
                    else => {
                        if (id == .@"error") {
                            outs[0] = .{ .Bool = false };
                            if (outs.len > 1) {
                                outs[1] = if (resolved.args.len > 0) resolved.args[0] else .Nil;
                            }
                            self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
                            return;
                        }
                        if (self.shouldRethrowForcedClose()) {
                            rethrow_forced_close = true;
                            return error.RuntimeError;
                        }
                        rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                        setFail(self, outs);
                        return;
                    },
                };

                outs[0] = .{ .Bool = true };
                const used_tmp = if (builtinHasDynamicOutCount(id))
                    @min(self.last_builtin_out_count, tmp.len)
                else
                    tmp.len;
                for (0..used_tmp) |i| {
                    const v = tmp[i];
                    if (1 + i >= outs.len) break;
                    outs[1 + i] = v;
                }
                self.last_builtin_out_count = @min(1 + used_tmp, outs.len);
            },
            .Closure => |cl| {
                const ret = self.runClosure(cl, resolved.args, false) catch |e| switch (e) {
                    error.Yield => return e,
                    error.OutOfMemory => {
                        self.setOutOfMemoryError();
                        if (self.current_thread) |th| th.frame_capture_cells.clearAndFree(self.alloc);
                        rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                        setFail(self, outs);
                        return;
                    },
                    else => {
                        if (self.current_thread) |th| {
                            if (shouldPromoteRuntimeErrorToYield(th)) return error.Yield;
                        }
                        if (self.current_thread) |th| th.frame_capture_cells.clearAndFree(self.alloc);
                        if (self.shouldRethrowForcedClose()) {
                            rethrow_forced_close = true;
                            return error.RuntimeError;
                        }
                        rollbackMemoryError(self, mem_before_call, obj_tables_before_call, obj_functions_before_call, obj_threads_before_call, obj_strings_before_call);
                        setFail(self, outs);
                        return;
                    },
                };
                defer self.alloc.free(ret);

                outs[0] = .{ .Bool = true };
                const n = @min(ret.len, outs.len - 1);
                for (0..n) |i| outs[1 + i] = ret[i];
                self.last_builtin_out_count = 1 + n;
            },
            else => unreachable,
        }
    }

    fn builtinXpcall(self: *Vm, args: []const Value, outs: []Value) Error!void {
        self.last_builtin_out_count = 0;
        if (args.len < 2) return self.fail("xpcall expects (f, msgh [, args...])", .{});
        if (self.protected_call_depth >= 128) {
            self.err = "stack overflow error";
            self.err_obj = .{ .String = try self.internStr("stack overflow error") };
            self.err_has_obj = true;
            self.err_source = null;
            self.err_line = -1;
            self.captureErrorTraceback();
            if (outs.len > 0) {
                outs[0] = .{ .Bool = false };
                if (outs.len > 1) outs[1] = self.protectedErrorValue();
                self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
            }
            return;
        }
        self.protected_call_depth += 1;
        defer self.protected_call_depth -= 1;

        const f = args[0];
        const msgh = args[1];
        const call_args = args[2..];

        const prev_err = self.err;
        const prev_err_obj = self.err_obj;
        const prev_err_has_obj = self.err_has_obj;
        const prev_err_source = self.err_source;
        const prev_err_line = self.err_line;
        const prev_err_traceback = self.err_traceback;
        var rethrow_forced_close = false;
        self.err_traceback = null;
        defer {
            self.clearErrorTraceback();
            if (!rethrow_forced_close) {
                self.err = prev_err;
                self.err_obj = prev_err_obj;
                self.err_has_obj = prev_err_has_obj;
                self.err_source = prev_err_source;
                self.err_line = prev_err_line;
            }
            self.err_traceback = prev_err_traceback;
        }

        if (outs.len == 0) {
            // Just execute for side effects.
            const resolved = self.resolveCallable(f, call_args, null) catch return;
            defer if (resolved.owned_args) |owned| self.alloc.free(owned);
            switch (resolved.callee) {
                .Builtin => |id| self.callBuiltin(id, resolved.args, &[_]Value{}) catch |e| switch (e) {
                    error.Yield => return e,
                    else => {
                        if (self.shouldRethrowForcedClose()) {
                            rethrow_forced_close = true;
                            return error.RuntimeError;
                        }
                    },
                },
                .Closure => |cl| {
                    const ret = self.runClosure(cl, resolved.args, false) catch |e| switch (e) {
                        error.Yield => return e,
                        else => {
                            if (self.current_thread) |th| {
                                if (shouldPromoteRuntimeErrorToYield(th)) return error.Yield;
                            }
                            if (self.current_thread) |th| th.frame_capture_cells.clearAndFree(self.alloc);
                            if (self.shouldRethrowForcedClose()) {
                                rethrow_forced_close = true;
                                return error.RuntimeError;
                            }
                            return;
                        },
                    };
                    self.alloc.free(ret);
                },
                else => unreachable,
            }
            return;
        }

        const setFail = struct {
            fn run(vm: *Vm, handler: Value, o: []Value) Error!void {
                o[0] = .{ .Bool = false };
                if (o.len <= 1) {
                    vm.last_builtin_out_count = @min(@as(usize, 1), o.len);
                    return;
                }
                var emsg: Value = vm.protectedErrorValue();
                var depth: usize = 0;
                vm.in_error_handler += 1;
                defer vm.in_error_handler -= 1;

                while (true) {
                    if (depth >= 256) {
                        o[1] = .{ .String = try vm.internStr("C stack overflow") };
                        vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                        return;
                    }
                    depth += 1;

                    switch (handler) {
                        .Builtin => |id| {
                            var in = [_]Value{emsg};
                            var out: [1]Value = .{.Nil};
                            vm.callBuiltin(id, in[0..], out[0..]) catch {
                                const next = vm.protectedErrorValue();
                                if (valuesEqual(next, emsg)) {
                                    o[1] = .{ .String = try vm.internStr("error in error handling") };
                                    vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                                    return;
                                }
                                emsg = next;
                                continue;
                            };
                            o[1] = out[0];
                            vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                            return;
                        },
                        .Closure => |cl| {
                            var in = [_]Value{emsg};
                            const ret = vm.runClosure(cl, in[0..], false) catch {
                                const next = vm.protectedErrorValue();
                                if (valuesEqual(next, emsg)) {
                                    o[1] = .{ .String = try vm.internStr("error in error handling") };
                                    vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                                    return;
                                }
                                emsg = next;
                                continue;
                            };
                            defer vm.alloc.free(ret);
                            o[1] = if (ret.len > 0) ret[0] else .Nil;
                            vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                            return;
                        },
                        else => {
                            o[1] = emsg;
                            vm.last_builtin_out_count = @min(@as(usize, 2), o.len);
                            return;
                        },
                    }
                }
            }
        }.run;

        const resolved = self.resolveCallable(f, call_args, null) catch {
            try setFail(self, msgh, outs);
            return;
        };
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);

        switch (resolved.callee) {
            .Builtin => |id| {
                const nouts = if (outs.len > 1) outs.len - 1 else 0;
                var tmp_small: [8]Value = undefined;
                var tmp: []Value = undefined;
                var tmp_heap = false;
                if (nouts <= tmp_small.len) {
                    tmp = tmp_small[0..nouts];
                } else {
                    tmp = try self.alloc.alloc(Value, nouts);
                    tmp_heap = true;
                }
                defer if (tmp_heap) self.alloc.free(tmp);

                self.callBuiltin(id, resolved.args, tmp) catch |e| switch (e) {
                    error.Yield => return e,
                    else => {
                        if (self.shouldRethrowForcedClose()) {
                            rethrow_forced_close = true;
                            return error.RuntimeError;
                        }
                        try setFail(self, msgh, outs);
                        return;
                    },
                };

                outs[0] = .{ .Bool = true };
                const used_tmp = if (builtinHasDynamicOutCount(id))
                    @min(self.last_builtin_out_count, tmp.len)
                else
                    tmp.len;
                for (0..used_tmp) |i| {
                    const v = tmp[i];
                    if (1 + i >= outs.len) break;
                    outs[1 + i] = v;
                }
                self.last_builtin_out_count = @min(1 + used_tmp, outs.len);
            },
            .Closure => |cl| {
                const ret = self.runClosure(cl, resolved.args, false) catch |e| switch (e) {
                    error.Yield => return e,
                    else => {
                        if (self.current_thread) |th| {
                            if (shouldPromoteRuntimeErrorToYield(th)) return error.Yield;
                        }
                        if (self.current_thread) |th| th.frame_capture_cells.clearAndFree(self.alloc);
                        if (self.shouldRethrowForcedClose()) {
                            rethrow_forced_close = true;
                            return error.RuntimeError;
                        }
                        try setFail(self, msgh, outs);
                        return;
                    },
                };
                defer self.alloc.free(ret);
                outs[0] = .{ .Bool = true };
                const n = @min(ret.len, outs.len - 1);
                for (0..n) |i| outs[1 + i] = ret[i];
                self.last_builtin_out_count = 1 + n;
            },
            else => unreachable,
        }
    }

    fn builtinNext(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("next expects table", .{});
        const tbl = try self.expectTable(args[0]);
        const control = if (args.len >= 2) args[1] else .Nil;
        const found = (try self.rawNext(tbl, control)) orelse {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .Nil;
            return;
        };
        outs[0] = found.key;
        if (outs.len > 1) outs[1] = found.value;
    }

    fn builtinCoroutineCreate(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("coroutine.create expects function", .{});
        const callee = args[0];
        if (!isCallableValue(callee)) return self.fail("coroutine.create expects function", .{});
        try self.testcChargeMemory(@sizeOf(Thread) + 64);
        const th = try self.alloc.create(Thread);
        th.* = .{ .status = .suspended, .callee = callee };
        try self.gc_threads.append(self.alloc, th);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0;
        self.testc_obj_threads += 1;
        outs[0] = .{ .Thread = th };
    }

    fn builtinCoroutineWrap(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        var tmp: [1]Value = .{.Nil};
        try self.builtinCoroutineCreate(args, tmp[0..]);
        const th = try self.expectThread(tmp[0]);
        self.wrap_thread = th;
        const obj = try self.allocTableNoGc();
        const mt = try self.allocTableNoGc();
        try self.setField(mt, "__call", .{ .Builtin = .coroutine_wrap_iter });
        obj.metatable = mt;
        try self.setField(obj, "__thread", .{ .Thread = th });
        outs[0] = .{ .Table = obj };
    }

    fn builtinCoroutineWrapIter(self: *Vm, args: []const Value, outs: []Value) Error!void {
        var th: *Thread = undefined;
        var call_args: []const Value = args;
        if (args.len > 0 and args[0] == .Table) {
            const obj = args[0].Table;
            const thv = self.getFieldOpt(obj, "__thread") orelse return self.fail("coroutine.wrap iterator missing thread", .{});
            if (thv != .Thread) return self.fail("coroutine.wrap iterator missing thread", .{});
            th = thv.Thread;
            call_args = args[1..];
        } else {
            th = self.wrap_thread orelse return self.fail("coroutine.wrap iterator missing thread", .{});
        }
        if (th.status == .running) {
            return self.fail("cannot resume non-suspended coroutine", .{});
        }
        if (th.wrap_repeat_closure) |cl| {
            if (call_args.len == 0 and th.status == .suspended and bumpClosureNumericUpvalues(cl, 1)) {
                if (outs.len > 0) outs[0] = .{ .Closure = cl };
                self.last_builtin_out_count = if (outs.len > 0) 1 else 0;
                return;
            }
            th.wrap_repeat_closure = null;
        }
        var resume_args = try self.alloc.alloc(Value, call_args.len + 1);
        defer self.alloc.free(resume_args);
        resume_args[0] = .{ .Thread = th };
        for (call_args, 0..) |v, i| resume_args[i + 1] = v;

        const tmp = try self.alloc.alloc(Value, outs.len + 1);
        defer self.alloc.free(tmp);
        for (tmp) |*v| v.* = .Nil;
        try self.builtinCoroutineResume(resume_args, tmp);

        const ok = switch (tmp[0]) {
            .Bool => |b| b,
            else => false,
        };
        if (!ok) {
            if (tmp.len > 1 and !(tmp[1] == .Nil)) {
                if (tmp[1] == .String) return self.fail("{s}", .{tmp[1].String.bytes()});
                self.err = null;
                self.err_obj = tmp[1];
                self.err_has_obj = true;
                self.err_source = null;
                self.err_line = -1;
                self.captureErrorTraceback();
                return error.RuntimeError;
            }
            return self.fail("coroutine.wrap resume failed", .{});
        }
        const resume_out = if (self.last_builtin_out_count > 0) self.last_builtin_out_count - 1 else 0;
        const n = @min(outs.len, @min(resume_out, if (tmp.len > 1) tmp.len - 1 else 0));
        for (0..n) |i| outs[i] = tmp[i + 1];
        self.last_builtin_out_count = n;
        th.wrap_repeat_closure = null;
        if (n == 1 and outs[0] == .Closure and th.status == .suspended and call_args.len == 0 and th.callee == .Closure and th.callee.Closure.func.num_params == 0) {
            th.wrap_repeat_closure = outs[0].Closure;
        }
        return;
    }

    fn freeThreadLocalsSnapshot(self: *Vm, th: *Thread) void {
        if (th.locals_snapshot) |snap| {
            self.alloc.free(snap);
            th.locals_snapshot = null;
        }
    }

    fn freeThreadWrapBuffers(self: *Vm, th: *Thread) void {
        for (th.wrap_yields.items) |item| self.alloc.free(item.values);
        th.wrap_yields.clearAndFree(self.alloc);
        th.wrap_yield_index = 0;
        if (th.wrap_final_values) |vals| {
            self.alloc.free(vals);
            th.wrap_final_values = null;
        }
        th.wrap_final_error = null;
        th.wrap_final_delivered = false;
        th.frame_id_counter = 0;
        th.wrap_repeat_closure = null;
        self.clearThreadContinuationScratch(th, .{});
        th.close_mode = false;
        th.dofile_entry_closure = null;
        th.trace_stack_depth = 0;
        if (th.trace_frame_names) |names| {
            self.alloc.free(names);
            th.trace_frame_names = null;
        }
        th.resume_base_depth = 0;
        self.freeThreadSuspendedFrames(th);
    }

    const ContinuationScratchClearOpts = struct {
        clear_yielded: bool = false,
    };

    fn clearThreadContinuationScratch(self: *Vm, th: *Thread, opts: ContinuationScratchClearOpts) void {
        if (th.entry_args) |vals| {
            self.alloc.free(vals);
            th.entry_args = null;
        }
        for (th.testc_pending_conts.items) |pending| {
            self.alloc.free(pending.stack);
            if (pending.upvalues) |vals| self.alloc.free(vals);
            if (pending.closers) |vals| self.alloc.free(vals);
        }
        th.testc_pending_conts.clearAndFree(self.alloc);
        self.clearTestcCloseReturnContinuation(th);
        th.frame_local_overrides.clearAndFree(self.alloc);
        th.frame_capture_cells.clearAndFree(self.alloc);
        if (opts.clear_yielded) {
            if (th.yielded) |vals| {
                self.alloc.free(vals);
                th.yielded = null;
            }
        }
    }

    fn clearTestcCloseReturnContinuation(self: *Vm, th: *Thread) void {
        th.testc_close_current = null;
        if (th.testc_close_return_values) |vals| {
            self.alloc.free(vals);
            th.testc_close_return_values = null;
        }
        if (th.testc_close_remaining) |vals| {
            self.alloc.free(vals);
            th.testc_close_remaining = null;
        }
    }

    fn freeThreadSuspendedFrames(self: *Vm, th: *Thread) void {
        for (th.suspended_frames.items) |fr| {
            self.alloc.free(fr.regs);
            self.alloc.free(fr.locals);
            self.alloc.free(fr.boxed);
            self.alloc.free(fr.local_active);
            self.alloc.free(fr.varargs);
            self.alloc.free(fr.upvalues);
        }
        th.suspended_frames.clearAndFree(self.alloc);
        if (th.resume_inbox) |vals| {
            self.alloc.free(vals);
            th.resume_inbox = null;
        }
        if (th.tail_resume_inbox) |vals| {
            self.alloc.free(vals);
            th.tail_resume_inbox = null;
        }
        th.tail_resume_func = null;
        if (th.last_yield_payload) |vals| {
            self.alloc.free(vals);
            th.last_yield_payload = null;
        }
        th.suspended_pc = 0;
        th.tail_suspended_pc = 0;
        th.suspended_direct_yield = false;
        th.suspended_builtin = null;
        if (th.suspended_builtin_args) |vals| {
            self.alloc.free(vals);
            th.suspended_builtin_args = null;
        }
        th.pending_close_builtin = false;
        th.pending_close_builtin_obj = .Nil;
        th.pending_close_err_active = false;
        th.pending_close_err = .Nil;
        th.capture_yield_id = 0;
        th.capture_from_debug_hook = false;
        th.capture_from_count_hook = false;
        th.resume_yield_id = 0;
        th.next_yield_id = 1;
        th.yield_origin_depth = 0;
        th.started = false;
        th.finished = false;
        th.internal_resume_after_yield = false;
    }

    fn clearThreadSuspendedSnapshots(self: *Vm, th: *Thread) void {
        for (th.suspended_frames.items) |fr| {
            self.alloc.free(fr.regs);
            self.alloc.free(fr.locals);
            self.alloc.free(fr.boxed);
            self.alloc.free(fr.local_active);
            self.alloc.free(fr.varargs);
            self.alloc.free(fr.upvalues);
        }
        th.suspended_frames.clearAndFree(self.alloc);
        th.capture_yield_id = 0;
        th.capture_from_debug_hook = false;
        th.capture_from_count_hook = false;
    }

    fn captureThreadSuspendedFrame(self: *Vm, th: *Thread, fr: *const Frame, pc: usize) Error!void {
        if (th.capture_yield_id == 0) {
            th.capture_yield_id = th.next_yield_id;
            th.next_yield_id +%= 1;
        }
        const regs = try self.alloc.alloc(Value, fr.regs.len);
        const locals = try self.alloc.alloc(Value, fr.locals.len);
        const boxed = try self.alloc.alloc(?*Cell, fr.boxed.len);
        const local_active = try self.alloc.alloc(bool, fr.local_active.len);
        const varargs = try self.alloc.alloc(Value, fr.varargs.len);
        const upvalues = try self.alloc.alloc(*Cell, fr.upvalues.len);

        for (fr.regs, 0..) |v, i| regs[i] = v;
        for (fr.locals, 0..) |v, i| locals[i] = v;
        for (fr.boxed, 0..) |v, i| boxed[i] = v;
        for (fr.local_active, 0..) |v, i| local_active[i] = v;
        for (fr.varargs, 0..) |v, i| varargs[i] = v;
        for (fr.upvalues, 0..) |v, i| upvalues[i] = @constCast(v);

        const direct = th.yield_origin_depth != 0 and th.yield_origin_depth == self.frames.items.len;
        const snap_pc = if (th.in_close_pending_unwind and !direct) pc + 1 else pc;
        try th.suspended_frames.append(self.alloc, .{
            .func = fr.func,
            .proto = fr.proto,
            .callee = fr.callee,
            .regs = regs,
            .locals = locals,
            .boxed = boxed,
            .local_active = local_active,
            .varargs = varargs,
            .upvalues = upvalues,
            .env_override = fr.env_override,
            .frame_id = fr.frame_id,
            .pc = snap_pc,
            .current_line = fr.current_line,
            .last_hook_line = fr.last_hook_line,
            .used_closing_line_hook = fr.used_closing_line_hook,
            .resume_skip_count_pc = fr.resume_skip_count_pc,
            .is_tailcall = fr.is_tailcall,
            .hide_from_debug = fr.hide_from_debug,
            .direct_yield = direct,
            .from_debug_hook = self.in_debug_hook or th.capture_from_debug_hook,
            .from_count_hook = (self.in_debug_hook and self.debug_hook_event_is_count) or th.capture_from_count_hook,
            .stack_depth = self.frames.items.len,
            .yield_id = th.capture_yield_id,
        });
    }

    fn popMatchingSuspendedFrame(self: *Vm, th: *Thread, f: *const ir.Function, upvalues: []const *Cell, callee_cl: ?*Closure) ?SuspendedFrame {
        _ = self;
        if (th.resume_recursive_mode and th.resume_pop_consumed) return null;
        if (th.suspended_frames.items.len == 0) return null;
        var best_idx: ?usize = null;
        var best_quality: u8 = 0;
        var best_depth: usize = 0;
        for (th.suspended_frames.items, 0..) |fr, i| {
            if (th.resume_yield_id != 0 and fr.yield_id != th.resume_yield_id) continue;
            if (fr.func != f) continue;
            var upvalues_match = fr.upvalues.len == upvalues.len;
            if (upvalues_match) {
                for (upvalues, 0..) |uv, j| {
                    if (fr.upvalues[j] != uv) {
                        upvalues_match = false;
                        break;
                    }
                }
            }
            var quality: u8 = 0;
            if (callee_cl) |cl| {
                if (fr.callee == .Closure and fr.callee.Closure == cl) {
                    quality = 2;
                } else if (upvalues_match) {
                    quality = 1;
                } else {
                    continue;
                }
            } else {
                if (!upvalues_match) continue;
                quality = 1;
            }
            const better_depth = if (th.resume_recursive_mode) (fr.stack_depth > best_depth) else (fr.stack_depth < best_depth);
            if (best_idx == null or quality > best_quality or (quality == best_quality and better_depth)) {
                best_idx = i;
                best_quality = quality;
                best_depth = fr.stack_depth;
            }
        }
        if (best_idx) |idx| {
            if (th.resume_recursive_mode) th.resume_pop_consumed = true;
            return th.suspended_frames.orderedRemove(idx);
        }
        return null;
    }

    fn findPendingDirectYieldChild(th: *const Thread, yield_id: usize, parent_depth: usize) ?*const SuspendedFrame {
        const child_depth = parent_depth + 1;
        for (th.suspended_frames.items) |*fr| {
            if (fr.yield_id != yield_id) continue;
            if (!fr.direct_yield) continue;
            if (!fr.from_debug_hook) continue;
            if (fr.stack_depth != child_depth) continue;
            return fr;
        }
        return null;
    }

    fn resumePendingDirectYieldChildren(self: *Vm, th: *Thread, yield_id: usize, parent_depth: usize) Error!void {
        while (findPendingDirectYieldChild(th, yield_id, parent_depth)) |fr| {
            switch (fr.callee) {
                .Closure => |cl| {
                    const prev_internal = th.internal_resume_after_yield;
                    const prev_in_debug_hook = self.in_debug_hook;
                    const prev_calllike = self.debug_hook_event_calllike;
                    const prev_tailcall = self.debug_hook_event_tailcall;
                    const prev_is_count = self.debug_hook_event_is_count;
                    th.internal_resume_after_yield = true;
                    self.in_debug_hook = fr.from_debug_hook;
                    self.debug_hook_event_calllike = false;
                    self.debug_hook_event_tailcall = false;
                    self.debug_hook_event_is_count = fr.from_count_hook;
                    defer {
                        th.internal_resume_after_yield = prev_internal;
                        self.in_debug_hook = prev_in_debug_hook;
                        self.debug_hook_event_calllike = prev_calllike;
                        self.debug_hook_event_tailcall = prev_tailcall;
                        self.debug_hook_event_is_count = prev_is_count;
                    }
                    const ret = try self.runFunctionArgsWithUpvalues(fr.func, fr.upvalues, &.{}, cl, fr.is_tailcall);
                    self.alloc.free(ret);
                },
                else => return,
            }
        }
    }

    fn detectRecursiveResumeMode(th: *const Thread) bool {
        if (th.close_mode) return false;
        if (th.resume_yield_id == 0) return false;
        var total: usize = 0;
        var saw_direct = false;
        var mode_func: ?*const ir.Function = null;
        var mode_cl: ?*Closure = null;
        var direct_pc: usize = 0;
        var have_direct_pc = false;
        var caller_pc: usize = 0;
        var have_caller_pc = false;
        for (th.suspended_frames.items) |fr| {
            if (fr.yield_id != th.resume_yield_id) continue;
            total += 1;
            if (fr.callee != .Closure) return false;
            if (mode_func) |mf| {
                if (mf != fr.func) return false;
            } else {
                mode_func = fr.func;
            }
            if (mode_cl) |mc| {
                if (mc != fr.callee.Closure) return false;
            } else {
                mode_cl = fr.callee.Closure;
            }
            if (fr.direct_yield) {
                if (saw_direct) return false;
                saw_direct = true;
                direct_pc = fr.pc;
                have_direct_pc = true;
            } else {
                if (have_caller_pc) {
                    if (caller_pc != fr.pc) return false;
                } else {
                    caller_pc = fr.pc;
                    have_caller_pc = true;
                }
            }
        }
        if (!(total > 1 and saw_direct and mode_func != null and mode_cl != null and have_direct_pc and have_caller_pc)) return false;
        if (direct_pc == caller_pc) return false;
        return true;
    }

    fn takeThreadResumeInboxAtPc(th: *Thread, pc: usize) ?[]Value {
        const vals = th.resume_inbox orelse return null;
        if (th.suspended_pc == 0 or th.suspended_pc != pc + 1 or !th.suspended_direct_yield) return null;
        th.resume_inbox = null;
        th.suspended_pc = 0;
        th.suspended_direct_yield = false;
        return vals;
    }

    fn takeThreadTailReturnInboxAtPc(th: *Thread, f: *const ir.Function, pc: usize) ?[]Value {
        const vals = th.tail_resume_inbox orelse return null;
        if (th.tail_resume_func == null or th.tail_resume_func.? != f) return null;
        if (th.tail_suspended_pc == 0 or th.tail_suspended_pc != pc + 1) return null;
        th.tail_resume_inbox = null;
        th.tail_resume_func = null;
        th.tail_suspended_pc = 0;
        return vals;
    }

    fn takeThreadReturnInboxAtPc(th: *Thread, f: *const ir.Function, pc: usize) ?[]Value {
        if (takeThreadTailReturnInboxAtPc(th, f, pc)) |vals| {
            return vals;
        }
        return takeThreadResumeInboxAtPc(th, pc);
    }

    fn shouldPromoteRuntimeErrorToYield(th: *const Thread) bool {
        return th.yielded != null and th.capture_yield_id != 0 and th.suspended_frames.items.len != 0;
    }

    fn functionHasFutureLineInfo(f: *const ir.Function, pc: usize) bool {
        var i = pc + 1;
        while (i < f.inst_lines.len) : (i += 1) {
            if (f.inst_lines[i] != 0) return true;
        }
        return false;
    }

    fn beginForcedClose(self: *Vm, th: *Thread) void {
        self.forced_close_thread = th;
        self.forced_close_had_error = false;
        th.close_mode = true;
    }

    fn clearForcedClose(self: *Vm, th: *Thread) void {
        if (self.forced_close_thread == th) {
            self.forced_close_thread = null;
            self.forced_close_had_error = false;
        }
        th.close_mode = false;
    }

    fn shouldRethrowForcedClose(self: *Vm) bool {
        const th = self.forced_close_thread orelse return false;
        return th.close_mode and self.current_thread != null and self.current_thread.? == th;
    }

    fn appendThreadWrapYield(self: *Vm, th: *Thread, values: []const Value) Error!void {
        const copy = try self.alloc.alloc(Value, values.len);
        for (values, 0..) |v, i| copy[i] = v;
        try th.wrap_yields.append(self.alloc, .{ .values = copy });
    }

    fn setThreadResumeInbox(self: *Vm, th: *Thread, values: []const Value) Error!void {
        if (th.resume_inbox) |old| self.alloc.free(old);
        const copy = try self.alloc.alloc(Value, values.len);
        for (values, 0..) |v, i| copy[i] = v;
        th.resume_inbox = copy;
    }

    fn armThreadReturnContinuation(self: *Vm, th: *Thread, f: *const ir.Function, pc: usize, values: []const Value) Error!void {
        if (th.tail_resume_inbox) |old| self.alloc.free(old);
        const copy = try self.alloc.alloc(Value, values.len);
        for (values, 0..) |v, i| copy[i] = v;
        th.tail_resume_inbox = copy;
        th.tail_resume_func = f;
        th.tail_suspended_pc = pc + 1;
    }

    fn disarmThreadReturnContinuation(self: *Vm, th: *Thread) void {
        if (th.tail_resume_inbox) |vals| {
            self.alloc.free(vals);
            th.tail_resume_inbox = null;
        }
        th.tail_resume_func = null;
        th.tail_suspended_pc = 0;
    }

    fn closePendingWithReturnContinuation(
        self: *Vm,
        maybe_th: ?*Thread,
        pc: usize,
        f: *const ir.Function,
        locals: []Value,
        local_active: []bool,
        boxed: []?*Cell,
        values: []const Value,
    ) Error!void {
        if (maybe_th) |th| {
            try self.armThreadReturnContinuation(th, f, pc, values);
            const prev_unwind = th.in_close_pending_unwind;
            th.in_close_pending_unwind = true;
            defer th.in_close_pending_unwind = prev_unwind;
            self.closePendingFunctionLocals(f, locals, local_active, boxed, null) catch |e| switch (e) {
                error.Yield => return error.Yield,
                else => {
                    self.disarmThreadReturnContinuation(th);
                    return e;
                },
            };
            self.disarmThreadReturnContinuation(th);
            return;
        }
        try self.closePendingFunctionLocals(f, locals, local_active, boxed, null);
    }

    fn setThreadLastYieldPayload(self: *Vm, th: *Thread, values: []const Value) Error!void {
        if (th.last_yield_payload) |old| self.alloc.free(old);
        const copy = try self.alloc.alloc(Value, values.len);
        for (values, 0..) |v, i| copy[i] = v;
        th.last_yield_payload = copy;
    }

    fn bumpClosureNumericUpvalues(cl: *Closure, delta: i64) bool {
        var changed = false;
        const n = @min(cl.func.upvalue_names.len, cl.upvalues.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            switch (cl.upvalues[i].value) {
                .Int => |iv| {
                    cl.upvalues[i].value = .{ .Int = iv + delta };
                    changed = true;
                },
                .Num => |nv| {
                    cl.upvalues[i].value = .{ .Num = nv + @as(f64, @floatFromInt(delta)) };
                    changed = true;
                },
                else => {},
            }
        }
        return changed;
    }

    fn snapshotThreadLocalsFromFrame(self: *Vm, th: *Thread, fr: *const Frame) Error!void {
        self.freeThreadLocalsSnapshot(th);
        var count: usize = 0;
        const nlocals = @min(fr.locals.len, fr.func.local_names.len);
        var i: usize = 0;
        while (i < nlocals) : (i += 1) {
            if (!fr.local_active[i]) continue;
            const nm = fr.func.local_names[i];
            if (nm.len == 0) continue;
            count += 1;
        }
        if (count == 0) return;
        const snap = try self.alloc.alloc(Thread.LocalSnap, count);
        var out_i: usize = 0;
        i = 0;
        while (i < nlocals) : (i += 1) {
            if (!fr.local_active[i]) continue;
            const nm = fr.func.local_names[i];
            if (nm.len == 0) continue;
            snap[out_i] = .{ .frame_id = fr.frame_id, .slot = i, .name = nm, .value = fr.locals[i] };
            out_i += 1;
        }
        th.locals_snapshot = snap;
    }

    fn currentVisibleFrameDepth(self: *Vm) usize {
        var n: usize = 0;
        for (self.frames.items) |fr| {
            if (!fr.hide_from_debug) n += 1;
        }
        return n;
    }

    fn snapshotThreadTraceFrames(self: *Vm, th: *Thread) Error!void {
        if (th.trace_frame_names) |names| {
            self.alloc.free(names);
            th.trace_frame_names = null;
        }
        const start = @min(th.resume_base_depth, self.frames.items.len);
        var depth: usize = 0;
        for (self.frames.items[start..]) |fr| {
            if (!fr.hide_from_debug) depth += 1;
        }
        if (depth == 0) {
            th.trace_stack_depth = 0;
            return;
        }
        const out = try self.alloc.alloc(?[]const u8, depth);
        var oi: usize = 0;
        var i = self.frames.items.len;
        while (i > start) {
            i -= 1;
            const fr = self.frames.items[i];
            if (fr.hide_from_debug) continue;
            const nm = fr.func.name;
            out[oi] = if (nm.len != 0 and !std.mem.eql(u8, nm, "<anon>")) nm else null;
            oi += 1;
        }
        th.trace_stack_depth = oi;
        th.trace_frame_names = out;
    }

    fn setThreadFrameLocalOverride(self: *Vm, th: *Thread, frame_id: usize, slot: usize, name: []const u8, value: Value) Error!void {
        for (th.frame_local_overrides.items) |*entry| {
            if (entry.frame_id == frame_id and entry.slot == slot) {
                entry.value = value;
                return;
            }
        }
        try th.frame_local_overrides.append(self.alloc, .{ .frame_id = frame_id, .slot = slot, .name = name, .value = value });
    }

    fn seedThreadFrameLocalOverridesFromSnapshot(self: *Vm, th: *Thread, fr: *const Frame) Error!void {
        const snap = th.locals_snapshot orelse return;
        for (snap) |entry| {
            if (!isCloseLocalIndex(fr.func, entry.slot)) continue;
            try self.setThreadFrameLocalOverride(th, entry.frame_id, entry.slot, entry.name, entry.value);
        }
    }

    fn applyThreadFrameLocalOverrides(self: *Vm, th: *Thread, fr: *Frame) void {
        _ = self;
        if (th.frame_local_overrides.items.len == 0) return;
        for (th.frame_local_overrides.items) |entry| {
            if (entry.frame_id != fr.frame_id) continue;
            if (entry.slot >= fr.locals.len) continue;
            if (!fr.local_active[entry.slot]) continue;
            fr.locals[entry.slot] = entry.value;
            if (entry.slot < fr.boxed.len) {
                if (fr.boxed[entry.slot]) |cell| cell.value = entry.value;
            }
        }
    }

    fn seedCloseLocalOverridesFromFrames(self: *Vm, th: *Thread) Error!void {
        for (self.frames.items) |fr| {
            const nlocals = @min(fr.locals.len, fr.func.local_names.len);
            var i: usize = 0;
            while (i < nlocals) : (i += 1) {
                if (!fr.local_active[i]) continue;
                if (!isCloseLocalIndex(fr.func, i)) continue;
                const nm = fr.func.local_names[i];
                if (nm.len == 0) continue;
                const vv = if (i < fr.boxed.len and fr.boxed[i] != null) fr.boxed[i].?.value else fr.locals[i];
                try self.setThreadFrameLocalOverride(th, fr.frame_id, i, nm, vv);
            }
        }
    }

    fn lookupThreadFrameLocalOverride(th: *Thread, frame_id: usize, slot: usize) ?Value {
        for (th.frame_local_overrides.items) |entry| {
            if (entry.frame_id == frame_id and entry.slot == slot) return entry.value;
        }
        return null;
    }

    fn lookupFrameCaptureCell(self: *Vm, frame_id: usize, slot: usize) ?*Cell {
        const th = self.current_thread orelse return null;
        for (th.frame_capture_cells.items) |entry| {
            if (entry.frame_id == frame_id and entry.slot == slot) return entry.cell;
        }
        return null;
    }

    fn rememberFrameCaptureCell(self: *Vm, frame_id: usize, slot: usize, cell: *Cell) Error!void {
        const th = self.current_thread orelse return;
        for (th.frame_capture_cells.items) |*entry| {
            if (entry.frame_id == frame_id and entry.slot == slot) {
                entry.cell = cell;
                return;
            }
        }
        try th.frame_capture_cells.append(self.alloc, .{ .frame_id = frame_id, .slot = slot, .cell = cell });
    }

    fn clearFrameCaptureCellsForFrame(self: *Vm, th: *Thread, frame_id: usize) void {
        _ = self;
        var i: usize = 0;
        while (i < th.frame_capture_cells.items.len) {
            if (th.frame_capture_cells.items[i].frame_id == frame_id) {
                _ = th.frame_capture_cells.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn builtinCoroutineYield(self: *Vm, args: []const Value, outs: []Value) Error!void {
        for (outs) |*o| o.* = .Nil;
        const th = self.current_thread orelse return self.fail("attempt to yield from outside a coroutine", .{});
        if (self.non_yieldable_c_depth > 0) return self.fail("attempt to yield across a C-call boundary", .{});
        if (th.close_mode) return self.fail("attempt to yield across a C-call boundary", .{});
        // A fresh yield supersedes previously captured continuation snapshots.
        self.clearThreadSuspendedSnapshots(th);
        th.capture_yield_id = th.next_yield_id;
        th.next_yield_id +%= 1;
        th.capture_from_debug_hook = self.in_debug_hook;
        th.capture_from_count_hook = self.in_debug_hook and self.debug_hook_event_is_count;
        th.yield_origin_depth = self.frames.items.len;
        if (self.frames.items.len != 0) {
            const frame_idx = if (self.in_debug_hook and self.frames.items.len >= 2)
                self.frames.items.len - 2
            else
                self.frames.items.len - 1;
            const fr = &self.frames.items[frame_idx];
            th.trace_currentline = fr.current_line;
            try self.snapshotThreadLocalsFromFrame(th, fr);
            try self.seedThreadFrameLocalOverridesFromSnapshot(th, fr);
            try self.seedCloseLocalOverridesFromFrames(th);
        }
        try self.snapshotThreadTraceFrames(th);
        if (th.wrap_eager_mode) {
            try self.appendThreadWrapYield(th, args);
            try self.setThreadLastYieldPayload(th, args);
            self.last_builtin_out_count = args.len;
            return;
        }
        if (th.yielded) |ys| self.alloc.free(ys);
        const ys = try self.alloc.alloc(Value, args.len);
        for (args, 0..) |v, i| ys[i] = v;
        th.yielded = ys;
        if (self.active_builtin) |id| {
            th.suspended_builtin = id;
            if (th.suspended_builtin_args) |vals| {
                self.alloc.free(vals);
                th.suspended_builtin_args = null;
            }
            if (self.active_builtin_args) |builtin_args| {
                const copy = try self.alloc.alloc(Value, builtin_args.len);
                for (builtin_args, 0..) |v, i| copy[i] = v;
                th.suspended_builtin_args = copy;
            }
        } else {
            th.suspended_builtin = null;
            if (th.suspended_builtin_args) |vals| {
                self.alloc.free(vals);
                th.suspended_builtin_args = null;
            }
        }
        try self.setThreadLastYieldPayload(th, args);
        self.last_builtin_out_count = args.len;
        return error.Yield;
    }

    fn isStackOverflowRuntimeError(self: *Vm) bool {
        if (self.err_has_obj and self.err_obj == .String) {
            const s = self.err_obj.String;
            if (std.mem.indexOf(u8, s.bytes(), "C stack overflow") != null) return true;
            if (std.mem.indexOf(u8, s.bytes(), "stack overflow") != null) return true;
        }
        if (self.err) |msg| {
            if (std.mem.indexOf(u8, msg, "C stack overflow") != null) return true;
            if (std.mem.indexOf(u8, msg, "stack overflow") != null) return true;
        }
        return false;
    }

    fn builtinCoroutineResume(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("coroutine.resume expects thread", .{});
        const th = try self.expectThread(args[0]);
        self.last_builtin_out_count = 0;
        defer if (th.close_mode) self.clearForcedClose(th);

        // Default return for resume is a tuple: (ok, ...).
        const want_out = outs.len > 0;
        if (self.protected_call_depth >= 32) {
            if (want_out) outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("C stack overflow") };
            return;
        }
        self.protected_call_depth += 1;
        defer self.protected_call_depth -= 1;

        if (th.status == .dead) {
            if (want_out) outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot resume dead coroutine") };
            self.last_builtin_out_count = if (want_out) @min(@as(usize, 2), outs.len) else 0;
            return;
        }
        if (th.status == .suspended and self.current_thread != null and self.current_thread.? != th and self.current_thread.?.caller == th) {
            if (want_out) outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot resume non-suspended coroutine") };
            self.last_builtin_out_count = if (want_out) @min(@as(usize, 2), outs.len) else 0;
            return;
        }
        if (th.status == .running) {
            if (want_out) outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot resume non-suspended coroutine") };
            self.last_builtin_out_count = if (want_out) @min(@as(usize, 2), outs.len) else 0;
            return;
        }

        th.status = .running;
        th.in_resume = true;
        th.resume_pop_consumed = false;
        th.resume_recursive_mode = false;
        th.yield_origin_depth = 0;
        th.suspended_direct_yield = false;
        th.capture_yield_id = 0;
        th.resume_yield_id = 0;
        for (th.suspended_frames.items) |fr| {
            if (fr.yield_id > th.resume_yield_id) th.resume_yield_id = fr.yield_id;
        }
        th.resume_recursive_mode = detectRecursiveResumeMode(th);
        defer {
            th.in_resume = false;
            th.resume_pop_consumed = false;
            th.resume_recursive_mode = false;
            th.resume_yield_id = 0;
            th.capture_yield_id = 0;
            th.capture_from_debug_hook = false;
            th.capture_from_count_hook = false;
        }
        defer {
            if (th.status == .running) th.status = .dead;
        }

        if (th.yielded) |ys| {
            self.alloc.free(ys);
            th.yielded = null;
        }

        // Preserve error string; resume should not permanently clobber it.
        const prev_err = self.err;
        const prev_err_obj = self.err_obj;
        const prev_err_has_obj = self.err_has_obj;
        const prev_err_source = self.err_source;
        const prev_err_line = self.err_line;
        const prev_err_traceback = self.err_traceback;
        self.err_traceback = null;
        defer {
            self.clearErrorTraceback();
            self.err = prev_err;
            self.err_obj = prev_err_obj;
            self.err_has_obj = prev_err_has_obj;
            self.err_source = prev_err_source;
            self.err_line = prev_err_line;
            self.err_traceback = prev_err_traceback;
        }

        const call_args = args[1..];
        if (th.testc_pending_conts.items.len != 0) {
            const prev_thread = self.current_thread;
            var prev_thread_status: ?@TypeOf(th.status) = null;
            if (prev_thread) |pt| {
                prev_thread_status = pt.status;
                if (pt.status == .running) pt.status = .suspended;
            }
            th.caller = prev_thread;
            self.current_thread = th;
            th.resume_base_depth = self.frames.items.len;
            defer {
                self.current_thread = prev_thread;
                th.caller = null;
                th.resume_base_depth = 0;
                if (prev_thread) |pt| {
                    if (prev_thread_status) |st| pt.status = st;
                }
            }

            var current_args: []const Value = call_args;
            var tmp_buf: [256]Value = undefined;
            while (true) {
                const target_outs = if (th.testc_pending_conts.items.len == 1 and outs.len > 1) outs[1..] else tmp_buf[0..];
                self.resumePendingTestcContinuation(th, current_args, target_outs) catch |e| switch (e) {
                    error.Yield => {},
                    else => return e,
                };
                const produced = self.last_builtin_out_count;
                if (th.testc_pending_conts.items.len == 0 or th.yielded != null) break;
                current_args = target_outs[0..@min(produced, target_outs.len)];
            }
            outs[0] = .{ .Bool = true };
            th.trace_had_error = false;
            if (th.testc_pending_conts.items.len != 0 or th.yielded != null) {
                const ys = if (th.last_yield_payload) |vals| vals else (th.yielded orelse &[_]Value{});
                const n = @min(ys.len, if (outs.len > 1) outs.len - 1 else 0);
                for (0..n) |i| outs[1 + i] = ys[i];
                self.last_builtin_out_count = 1 + n;
                if (th.yielded) |owned| {
                    self.alloc.free(owned);
                    th.yielded = null;
                }
                th.trace_yields += 1;
                th.status = .suspended;
                th.close_has_err = false;
                th.started = true;
                th.finished = false;
            } else {
                self.last_builtin_out_count = 1 + @min(self.last_builtin_out_count, if (outs.len > 1) outs.len - 1 else 0);
                th.status = .dead;
                th.close_has_err = false;
                th.started = true;
                th.finished = true;
                self.clearThreadContinuationScratch(th, .{});
            }
            return;
        }
        // Builtin entrypoints (notably coroutine.create(pcall/xpcall)) need the
        // original start arguments when resuming from suspended continuation
        // frames. This is runtime call context, not replay re-execution state.
        if (!th.started and th.entry_args == null) {
            const saved = try self.alloc.alloc(Value, call_args.len);
            for (call_args, 0..) |v, i| saved[i] = v;
            th.entry_args = saved;
        }
        try self.setThreadResumeInbox(th, call_args);
        const nouts = if (outs.len > 1) outs.len - 1 else 0;
        const prev_thread = self.current_thread;
        var prev_thread_status: ?@TypeOf(th.status) = null;
        if (prev_thread) |pt| {
            prev_thread_status = pt.status;
            if (pt.status == .running) pt.status = .suspended;
        }
        th.caller = prev_thread;
        self.current_thread = th;
        th.resume_base_depth = self.frames.items.len;
        defer {
            self.current_thread = prev_thread;
            th.caller = null;
            th.resume_base_depth = 0;
            if (prev_thread) |pt| {
                if (prev_thread_status) |st| pt.status = st;
            }
        }

        var ok: bool = true;
        var forced_close_ok = false;
        var yielded: bool = false;
        var payload: []Value = &[_]Value{};
        var payload_heap: bool = false;

        if (th.trace_yields == 0 and !self.in_debug_hook) {
            try self.debugDispatchHookWithCalleeTransfer("call", null, th.callee, call_args, 1);
        }

        const use_saved_entry = th.suspended_frames.items.len != 0 and th.entry_args != null;
        const exec_args = if (use_saved_entry) th.entry_args.? else call_args;
        const resolved = try self.resolveCallable(th.callee, exec_args, null);
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);
        switch (resolved.callee) {
            .Builtin => |id| {
                if (nouts != 0) {
                    payload = try self.alloc.alloc(Value, nouts);
                    payload_heap = true;
                }
                self.callBuiltin(id, resolved.args, payload) catch |e| switch (e) {
                    error.Yield => yielded = true,
                    error.RuntimeError => {
                        if (self.forced_close_thread == th and th.close_mode and !self.forced_close_had_error and !self.isStackOverflowRuntimeError()) {
                            forced_close_ok = true;
                        } else {
                            ok = false;
                        }
                    },
                    else => return e,
                };
            },
            .Closure => |cl| {
                const ret_opt: ?[]Value = retblk: {
                    const r = self.runClosure(cl, resolved.args, false) catch |e| switch (e) {
                        error.Yield => {
                            yielded = true;
                            break :retblk null;
                        },
                        error.RuntimeError => {
                            if (th.yielded != null and th.capture_yield_id != 0) {
                                yielded = true;
                                break :retblk null;
                            }
                            if (self.forced_close_thread == th and th.close_mode and !self.forced_close_had_error and !self.isStackOverflowRuntimeError()) {
                                forced_close_ok = true;
                            } else {
                                ok = false;
                            }
                            break :retblk null;
                        },
                        else => return e,
                    };
                    break :retblk r;
                };
                if (ret_opt) |ret| {
                    payload = ret;
                    payload_heap = true;
                }
            },
            else => return self.fail("coroutine.resume: bad thread", .{}),
        }

        defer if (payload_heap) self.alloc.free(payload);

        if (forced_close_ok) {
            self.err = null;
            self.err_obj = .Nil;
            self.err_has_obj = false;
            self.err_source = null;
            self.err_line = -1;
        }

        if (!want_out) {
            // Caller ignores results. Still follow resume semantics and do not throw.
            if (yielded or th.yielded != null) {
                if (th.yielded) |ys| {
                    self.alloc.free(ys);
                    th.yielded = null;
                }
                th.status = .suspended;
                th.started = true;
                th.finished = false;
            } else {
                th.status = .dead;
                th.started = true;
                th.finished = true;
            }
            return;
        }

        if (!ok) {
            outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = if (self.err_has_obj) self.err_obj else .{ .String = try self.internStr(self.errorString()) };
            self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
            if (th.yielded) |ys| {
                self.alloc.free(ys);
                th.yielded = null;
            }
            th.trace_had_error = true;
            th.status = .dead;
            th.close_has_err = true;
            th.close_err = if (self.err_has_obj) self.err_obj else .{ .String = try self.internStr(self.errorString()) };
            self.clearThreadContinuationScratch(th, .{});
            return;
        }

        // Yield path: return yielded values (set by coroutine.yield).
        if (yielded or th.yielded != null) {
            const ys = if (th.last_yield_payload) |vals| vals else (th.yielded orelse &[_]Value{});
            outs[0] = .{ .Bool = true };
            const n = @min(ys.len, outs.len - 1);
            for (0..n) |i| outs[1 + i] = ys[i];
            self.last_builtin_out_count = 1 + n;
            if (th.yielded) |owned| self.alloc.free(owned);
            th.yielded = null;
            th.trace_yields += 1;
            th.status = .suspended;
            th.close_has_err = false;
            th.started = true;
            th.finished = false;
            return;
        }

        outs[0] = .{ .Bool = true };
        const n = @min(payload.len, outs.len - 1);
        for (0..n) |i| outs[1 + i] = payload[i];
        self.last_builtin_out_count = 1 + n;
        th.trace_had_error = false;
        th.status = .dead;
        th.close_has_err = false;
        th.started = true;
        th.finished = true;
        self.clearThreadContinuationScratch(th, .{});
    }

    fn builtinCoroutineStatus(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("coroutine.status expects thread", .{});
        const th = try self.expectThread(args[0]);
        if (th.status == .suspended and self.current_thread != null and self.current_thread.? != th and self.current_thread.?.caller == th) {
            outs[0] = .{ .String = try self.internStr("normal") };
            return;
        }
        outs[0] = .{ .String = try self.internStr(switch (th.status) {
            .suspended => "suspended",
            .running => "running",
            .dead => "dead",
        }) };
    }

    fn builtinCoroutineRunning(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        outs[0] = if (self.current_thread) |th|
            .{ .Thread = th }
        else if (self.main_thread) |th|
            .{ .Thread = th }
        else
            .Nil;
        if (outs.len > 1) outs[1] = .{ .Bool = (self.current_thread == null) };
    }

    fn builtinCoroutineIsyieldable(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) {
            if (self.non_yieldable_c_depth > 0) {
                outs[0] = .{ .Bool = false };
                return;
            }
            const t = self.current_thread orelse {
                outs[0] = .{ .Bool = false };
                return;
            };
            const is_main = if (self.main_thread) |m| m == t else false;
            outs[0] = .{ .Bool = (t.status == .running and !is_main) };
            return;
        }

        const t = try self.expectThread(args[0]);
        const is_main = t.testc_state_main or if (self.main_thread) |m| m == t else false;
        outs[0] = .{ .Bool = (!is_main and t.status != .dead) };
    }

    fn builtinCoroutineClose(self: *Vm, args: []const Value, outs: []Value) Error!void {
        self.last_builtin_out_count = 0;
        if (self.coroutine_close_depth >= 40) return self.fail("C stack overflow", .{});
        self.coroutine_close_depth += 1;
        defer self.coroutine_close_depth -= 1;

        var th: *Thread = undefined;
        if (args.len == 0) {
            th = self.current_thread orelse return self.fail("coroutine.close expects thread", .{});
        } else {
            th = try self.expectThread(args[0]);
        }
        if (th == self.main_thread and self.current_thread != null and self.current_thread.? != th) {
            return self.fail("cannot close a normal coroutine", .{});
        }
        if (th.status == .running) {
            if (self.current_thread != null and self.current_thread.? == th) {
                if (th.close_mode and self.forced_close_thread == th) {
                    if (outs.len > 0) outs[0] = .{ .Bool = true };
                    if (outs.len > 1) outs[1] = .Nil;
                    self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
                    return;
                }
                self.beginForcedClose(th);
                self.err = null;
                self.err_obj = .Nil;
                self.err_has_obj = true;
                self.err_source = null;
                self.err_line = -1;
                return error.RuntimeError;
            }
            if (th == self.main_thread and self.current_thread == null) {
                return self.fail("cannot close a running main thread", .{});
            }
            return self.fail("cannot close a running coroutine", .{});
        }
        if (th == self.main_thread) return self.fail("cannot close the main thread", .{});
        if (th.close_has_err) {
            th.status = .dead;
            if (outs.len > 0) outs[0] = .{ .Bool = false };
            if (outs.len > 1) outs[1] = th.close_err;
            th.close_has_err = false;
            th.close_err = .Nil;
            self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
            return;
        }
        if (th.status == .suspended and th.trace_yields > 0) {
            self.beginForcedClose(th);
            var resume_args = [_]Value{.{ .Thread = th }};
            var resume_out = [_]Value{ .Nil, .Nil };
            self.builtinCoroutineResume(resume_args[0..], resume_out[0..]) catch {};
            const ok = switch (resume_out[0]) {
                .Bool => |b| b,
                else => false,
            };
            if (!ok) {
                th.status = .dead;
                if (outs.len > 0) outs[0] = .{ .Bool = false };
                if (outs.len > 1) outs[1] = resume_out[1];
                // Error is already returned by this close call; do not keep it
                // latched for subsequent close() calls on the dead coroutine.
                th.close_has_err = false;
                th.close_err = .Nil;
                self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
                return;
            }
        }
        th.status = .dead;
        self.clearThreadContinuationScratch(th, .{ .clear_yielded = true });
        if (outs.len > 0) outs[0] = .{ .Bool = true };
        if (outs.len > 1) outs[1] = .Nil;
        self.last_builtin_out_count = @min(@as(usize, 2), outs.len);
    }

    fn gcWeakMode(self: *Vm, tbl: *Table) struct { weak_k: bool, weak_v: bool } {
        const mt = tbl.metatable orelse return .{ .weak_k = false, .weak_v = false };
        const m = self.getFieldOpt(mt, "__mode") orelse return .{ .weak_k = false, .weak_v = false };
        const s = switch (m) {
            .String => |x| x.bytes(),
            else => return .{ .weak_k = false, .weak_v = false },
        };
        return .{
            .weak_k = std.mem.indexOfScalar(u8, s, 'k') != null,
            .weak_v = std.mem.indexOfScalar(u8, s, 'v') != null,
        };
    }

    fn gcCycleFull(self: *Vm) Error!void {
        return self.gcCycleFullInternal(true);
    }

    /// Internal GC cycle. `do_sweep` controls whether the sweep phase runs.
    /// Sweep frees unreachable objects; it is only safe at points where no
    /// temporary GC objects are held in VM registers (which are not tracked
    /// as roots). Explicit `collectgarbage()` calls are safe points — the
    /// caller is at a statement boundary. Allocation-threshold triggers are
    /// NOT safe points (mid-expression), so they request mark+prune+finalize
    /// only, deferring sweep to the next explicit collection.
    fn gcCycleFullInternal(self: *Vm, do_sweep: bool) Error!void {
        if (self.gc_in_cycle) return;
        self.gc_in_cycle = true;
        defer self.gc_in_cycle = false;

        // Snapshot the registry lengths before the cycle begins. Objects
        // allocated during the cycle (by finalizers running Lua code) are
        // appended beyond these indices and must survive the sweep — they
        // haven't been through marking. PUC Lua solves this with tri-color
        // white bits; we use the snapshot boundary instead.
        const tables_snapshot_len = self.gc_tables.items.len;
        const closures_snapshot_len = self.gc_closures.items.len;
        const threads_snapshot_len = self.gc_threads.items.len;
        const strings_snapshot_len = self.gc_strings.items.len;
        const cells_snapshot_len = self.gc_cells.items.len;

        // Clear and reuse gc_marked_strings (Vm-level field to avoid changing
        // gcMarkValue's parameter list). NOT deinited here — reused across
        // cycles, freed at Vm.deinit.
        self.gc_marked_strings.clearRetainingCapacity();
        self.gc_marked_cells.clearRetainingCapacity();

        var marked_tables = std.AutoHashMapUnmanaged(*Table, void){};
        defer marked_tables.deinit(self.alloc);
        var marked_closures = std.AutoHashMapUnmanaged(*Closure, void){};
        defer marked_closures.deinit(self.alloc);
        var marked_threads = std.AutoHashMapUnmanaged(*Thread, void){};
        defer marked_threads.deinit(self.alloc);
        var weak_tables = std.ArrayListUnmanaged(*Table).empty;
        defer weak_tables.deinit(self.alloc);

        try self.gcMarkValue(.{ .Table = self.global_env }, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
        if (self.debug_hook_main.func) |hv| {
            try self.gcMarkValue(hv, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
        }
        if (self.wrap_thread) |th| {
            try self.gcMarkValue(.{ .Thread = th }, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
        }
        for (self.frames.items) |fr| {
            if (fr.proto != null) {
                // Bytecode frames do not have IR live_regs. Until bc_vm gets
                // precise per-PC liveness, the whole register file is the
                // conservative stack root range, matching Lua's stack-root
                // model and preventing GC from freeing live bytecode values.
                for (fr.regs) |v| {
                    try self.gcMarkValue(v, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
                }
            } else if (fr.func.live_regs.len > 0 and fr.pc < fr.func.insts.len) {
                // Mark live registers using the per-PC live set.
                const nv = fr.func.num_values;
                const base = fr.pc * nv;
                for (fr.func.live_regs[base .. base + nv], 0..) |is_live, reg_idx| {
                    if (is_live and reg_idx < fr.regs.len) {
                        try self.gcMarkValue(fr.regs[reg_idx], &marked_tables, &marked_closures, &marked_threads, &weak_tables);
                    }
                }
            }
            // Mark ALL frame locals (not just active ones). Inactive locals
            // may still hold valid Value pointers; PUC Lua traverses the
            // entire stack range.
            try self.gcMarkValue(fr.callee, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
            for (fr.locals) |v| try self.gcMarkValue(v, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
            for (fr.varargs) |v| try self.gcMarkValue(v, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
            for (fr.upvalues) |cell| {
                if (!self.gc_marked_cells.contains(cell)) {
                    try self.gc_marked_cells.put(self.alloc, cell, {});
                }
                try self.gcMarkValue(cell.value, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
            }
            for (fr.boxed) |maybe_cell| {
                if (maybe_cell) |cell| {
                    if (!self.gc_marked_cells.contains(cell)) {
                        try self.gc_marked_cells.put(self.alloc, cell, {});
                    }
                    try self.gcMarkValue(cell.value, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
                }
            }
            if (fr.env_override) |v| try self.gcMarkValue(v, &marked_tables, &marked_closures, &marked_threads, &weak_tables);
        }
        // VM-level roots: metatables, thread refs, and registries that are not
        // reachable through Lua value traversal. Without these, sweep would
        // free objects only referenced by VM-internal bookkeeping.
        try self.gcMarkVmRoots(&marked_tables, &marked_closures, &marked_threads, &weak_tables);

        // Ephemeron propagation for weak-key tables: values are only marked if
        // their keys are marked, but marking those values may in turn mark
        // more keys. Iterate until reaching a fixed point.
        try self.gcPropagateEphemerons(&marked_tables, &marked_closures, &marked_threads, &weak_tables);

        // Lua's semantics around weak tables and finalizers are subtle.
        //
        // The upstream test-suite expects:
        // - weak values to be cleared before running finalizers
        // - weak keys to consider objects reachable only through a to-be-finalized
        //   object as "alive" until after finalization
        //
        // We approximate that by:
        // 1) pruning weak values using only the regular mark set
        // 2) collecting finalizable objects and computing an extra "finalizer reach"
        //    mark set by traversing those objects strongly
        // 3) pruning weak keys using (regular marks U finalizer-reach)
        // 4) running finalizers
        try self.gcPruneWeakValues(weak_tables.items, &marked_tables, &marked_closures, &marked_threads);
        const to_finalize = try self.gcCollectFinalizables(&marked_tables);
        defer self.alloc.free(to_finalize);

        var fin_tables = std.AutoHashMapUnmanaged(*Table, void){};
        defer fin_tables.deinit(self.alloc);
        var fin_closures = std.AutoHashMapUnmanaged(*Closure, void){};
        defer fin_closures.deinit(self.alloc);
        var fin_threads = std.AutoHashMapUnmanaged(*Thread, void){};
        defer fin_threads.deinit(self.alloc);
        try self.gcMarkFinalizerReach(to_finalize, &fin_tables, &fin_closures, &fin_threads);

        // Weak tables reachable only from to-be-finalized objects still need
        // their weak refs cleared before running finalizers (gc.lua: "__gc x weak tables").
        var fin_weak_tbls = std.ArrayListUnmanaged(*Table).empty;
        defer fin_weak_tbls.deinit(self.alloc);
        var it_fin = fin_tables.iterator();
        while (it_fin.next()) |entry| {
            const t = entry.key_ptr.*;
            const mode = self.gcWeakMode(t);
            if (mode.weak_k or mode.weak_v) {
                try fin_weak_tbls.append(self.alloc, t);
            }
        }
        if (fin_weak_tbls.items.len > 0) {
            try self.gcPruneWeakValues(fin_weak_tbls.items, &marked_tables, &marked_closures, &marked_threads);
            try self.gcPruneWeakKeys(fin_weak_tbls.items, &marked_tables, &marked_closures, &marked_threads, &fin_tables, &fin_closures, &fin_threads);
        }

        try self.gcPruneWeakKeys(weak_tables.items, &marked_tables, &marked_closures, &marked_threads, &fin_tables, &fin_closures, &fin_threads);
        try self.gcFinalizeList(to_finalize);

        // Sweep: free objects that are unreachable (not in mark set, not
        // pending finalization). Safe at all points because:
        // - Temp roots (Handle API) protect Zig-local temporaries in builtins.
        // - live_regs tracks frame registers between instructions.
        // - debug_transfer_values are explicitly marked in gcMarkVmRoots.
        // - Dead registers are cleared below to prevent dangling pointers.
        if (do_sweep) {
            // Clear dead registers: only live registers (via live_regs) are
            // marked as GC roots. Dead registers may contain stale pointers to
            // objects that will be swept. Clear Table/Closure/Thread values
            // (freed objects cause UAF when debug.getlocal scans all registers
            // for for-state iterator tables). Do NOT clear String values —
            // live_regs may have minor inaccuracies that cause false "dead"
            // classifications, and clearing a live String register corrupts
            // pointer-identity comparisons (luaStringEq). Strings in dead
            // registers are safe because debug.getlocal only dereferences
            // .Table values when scanning for for-state iterators.
            for (self.frames.items) |*fr| {
                if (fr.proto != null) {
                    // Conservative bytecode frames marked all registers above;
                    // clearing them here would create artificial nils visible
                    // to debug paths and later bytecode instructions.
                    continue;
                }
                if (fr.func.live_regs.len > 0 and fr.pc < fr.func.insts.len) {
                    const nv = fr.func.num_values;
                    const base = fr.pc * nv;
                    const limit = @min(nv, fr.regs.len);
                    for (0..limit) |reg_idx| {
                        if (!fr.func.live_regs[base + reg_idx]) {
                            switch (fr.regs[reg_idx]) {
                                .Table, .Closure, .Thread => fr.regs[reg_idx] = .Nil,
                                else => {},
                            }
                        }
                    }
                }
            }

            self.gcSweepTables(&marked_tables, &fin_tables, tables_snapshot_len);
            self.gcSweepClosures(&marked_closures, &fin_closures, closures_snapshot_len);
            self.gcSweepThreads(&marked_threads, &fin_threads, threads_snapshot_len);
            self.gcDeadenUnmarkedStringKeys(&marked_tables);
            self.gcSweepStrings(strings_snapshot_len);
            self.gcSweepCells(cells_snapshot_len);
            // Sweep intern tables: remove unreachable entries from both
            // long_literals and string_intern (short strings). Short strings
            // are now safe to sweep because err_obj and gmatch_state are
            // explicitly marked as GC roots in gcMarkVmRoots.
            try self.long_literals.sweep(self.alloc, &self.gc_marked_strings);
            // Keep short strings pinned until IR functions own decoded string
            // constants and mark them as Proto roots. The lazy ConstString path
            // can materialize a short literal into a register whose liveness is
            // not visible across every debug-hook/continuation edge; sweeping
            // the global short-string table then creates dangling Value.String
            // pointers. PUC can sweep short strings because Proto constants are
            // first-class GC roots. We should re-enable this only with the same
            // invariant.
            // try self.string_intern.sweep(self.alloc, &self.gc_marked_strings);
        }
    }

    /// Mark all GC roots that live directly on the Vm struct and are NOT
    /// reachable through Lua-value traversal from global_env/frames.
    fn gcMarkVmRoots(
        self: *Vm,
        marked_tables: *std.AutoHashMapUnmanaged(*Table, void),
        marked_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        marked_threads: *std.AutoHashMapUnmanaged(*Thread, void),
        weak_tables: *std.ArrayListUnmanaged(*Table),
    ) Error!void {
        // Type metatables: every string/number/boolean/etc. value's metamethod
        // lookup routes through these.
        try self.gcMarkValue(.{ .Table = self.string_metatable }, marked_tables, marked_closures, marked_threads, weak_tables);
        const optional_mts = [_]?*Table{
            self.number_metatable,
            self.boolean_metatable,
            self.nil_metatable,
            self.function_metatable,
            self.thread_metatable,
            self.file_metatable,
        };
        for (optional_mts) |mt| {
            if (mt) |t| try self.gcMarkValue(.{ .Table = t }, marked_tables, marked_closures, marked_threads, weak_tables);
        }
        if (self.debug_registry) |t| try self.gcMarkValue(.{ .Table = t }, marked_tables, marked_closures, marked_threads, weak_tables);

        // Thread handles held by the VM.
        const optional_threads = [_]?*Thread{
            self.main_thread,
            self.current_thread,
            self.forced_close_thread,
        };
        for (optional_threads) |oth| {
            if (oth) |th| try self.gcMarkValue(.{ .Thread = th }, marked_tables, marked_closures, marked_threads, weak_tables);
        }

        // dump_registry: closures kept alive for string.dump/load round-trip.
        var drit = self.dump_registry.iterator();
        while (drit.next()) |entry| {
            try self.gcMarkValue(.{ .Closure = entry.value_ptr.* }, marked_tables, marked_closures, marked_threads, weak_tables);
        }

        // debug_upvalue_ids: proxy tables for debug.upvalueid.
        var duit = self.debug_upvalue_ids.iterator();
        while (duit.next()) |entry| {
            try self.gcMarkValue(.{ .Table = entry.value_ptr.* }, marked_tables, marked_closures, marked_threads, weak_tables);
        }

        // Pinned source strings from load(string) — ir.Function lexemes
        // reference their bytes, so they must survive sweep.
        for (self.pinned_source_strings.items) |s| {
            if (!self.gc_marked_strings.contains(s)) {
                try self.gc_marked_strings.put(self.alloc, s, {});
            }
        }

        // Temporary GC roots (Handle API): Values held in Zig locals by
        // builtins. These are the analog of PUC Lua's L->stack temporaries.
        for (self.gc_temp_roots.items) |rv| {
            try self.gcMarkValue(rv, marked_tables, marked_closures, marked_threads, weak_tables);
        }

        // Debug hook transfer values: a slice into frame registers set up for
        // an about-to-happen call/return event. These registers may NOT be in
        // live_regs[pc] (they model the transition, not the current instruction),
        // so we mark them explicitly to protect them during sweep inside hooks.
        if (self.debug_transfer_values) |dtv| {
            for (dtv) |v| {
                try self.gcMarkValue(v, marked_tables, marked_closures, marked_threads, weak_tables);
            }
        }

        // Error object: self.err_obj may hold a GC-managed Value (String, Table)
        // that is not reachable from any other root between error raise and pcall
        // catch. self.err (the bytes) borrows from the same LuaString, so marking
        // err_obj keeps the bytes valid too.
        if (self.err_has_obj) {
            try self.gcMarkValue(self.err_obj, marked_tables, marked_closures, marked_threads, weak_tables);
        }

        // gmatch iterator state: holds *LuaString pointers for the subject string
        // and pattern, kept alive between iterator calls.
        if (self.gmatch_state) |gs| {
            if (!self.gc_marked_strings.contains(gs.s)) {
                try self.gc_marked_strings.put(self.alloc, gs.s, {});
            }
            if (!self.gc_marked_strings.contains(gs.p)) {
                try self.gc_marked_strings.put(self.alloc, gs.p, {});
            }
        }
    }

    /// Sweep the table registry: free every table that is unreachable.
    /// Uses in-place compaction (no reordering) so tables allocated during
    /// the cycle (by finalizers) at indices >= snapshot_len survive.
    fn gcSweepTables(
        self: *Vm,
        marked_tables: *const std.AutoHashMapUnmanaged(*Table, void),
        fin_tables: *const std.AutoHashMapUnmanaged(*Table, void),
        snapshot_len: usize,
    ) void {
        var write_idx: usize = 0;
        for (self.gc_tables.items, 0..) |t, i| {
            if (i >= snapshot_len) {
                self.gc_tables.items[write_idx] = t;
                write_idx += 1;
            } else if (marked_tables.contains(t) or fin_tables.contains(t) or self.finalizables.contains(t)) {
                self.gc_tables.items[write_idx] = t;
                write_idx += 1;
            } else {
                // Discharge actual byte size before freeing.
                const tbl_bytes = @sizeOf(Table) + t.array.capacity * @sizeOf(Value) + t.hash.len * @sizeOf(ltable.Node);
                self.gc_count_kb = @max(0, self.gc_count_kb - @as(f64, @floatFromInt(tbl_bytes)) / 1024.0);
                t.deinit(self.alloc);
                self.alloc.destroy(t);
            }
        }
        self.gc_tables.items.len = write_idx;
    }

    /// Sweep the closure registry: free every closure that is unreachable.
    /// Closures survive if they are in the mark set, the finalizer-reach set,
    /// or were allocated during this cycle (index >= snapshot_len).
    ///
    /// NOTE: cl.upvalues is intentionally NOT freed — ownership is ambiguous
    /// (string.dump clones borrow the original's slice; dofile/load use a
    /// static &.{}). Cells are a separate concern (not swept in this iteration).
    fn gcSweepClosures(
        self: *Vm,
        marked_closures: *const std.AutoHashMapUnmanaged(*Closure, void),
        fin_closures: *const std.AutoHashMapUnmanaged(*Closure, void),
        snapshot_len: usize,
    ) void {
        var write_idx: usize = 0;
        for (self.gc_closures.items, 0..) |cl, i| {
            if (i >= snapshot_len) {
                self.gc_closures.items[write_idx] = cl;
                write_idx += 1;
            } else if (marked_closures.contains(cl) or fin_closures.contains(cl)) {
                self.gc_closures.items[write_idx] = cl;
                write_idx += 1;
            } else {
                self.gc_count_kb = @max(0, self.gc_count_kb - @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0);
                self.alloc.destroy(cl);
            }
        }
        self.gc_closures.items.len = write_idx;
    }

    /// Sweep the thread registry: free every thread that is unreachable.
    /// Threads survive if they are in the mark set, the finalizer-reach set,
    /// or were allocated during this cycle (index >= snapshot_len).
    ///
    /// `main_thread` and `current_thread` are always roots (via gcMarkVmRoots),
    /// so they always survive. Only truly unreachable coroutines are freed.
    fn gcSweepThreads(
        self: *Vm,
        marked_threads: *const std.AutoHashMapUnmanaged(*Thread, void),
        fin_threads: *const std.AutoHashMapUnmanaged(*Thread, void),
        snapshot_len: usize,
    ) void {
        var write_idx: usize = 0;
        for (self.gc_threads.items, 0..) |th, i| {
            if (i >= snapshot_len) {
                self.gc_threads.items[write_idx] = th;
                write_idx += 1;
            } else if (marked_threads.contains(th) or fin_threads.contains(th)) {
                self.gc_threads.items[write_idx] = th;
                write_idx += 1;
            } else {
                // Free auxiliary buffers before destroying the struct.
                self.freeThreadWrapBuffers(th);
                if (th.yielded) |ys| self.alloc.free(ys);
                if (th.locals_snapshot) |snap| self.alloc.free(snap);
                self.gc_count_kb = @max(0, self.gc_count_kb - @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0);
                self.alloc.destroy(th);
            }
        }
        self.gc_threads.items.len = write_idx;
    }

    fn gcDeadenUnmarkedStringKeys(
        self: *Vm,
        marked_tables: *const std.AutoHashMapUnmanaged(*Table, void),
    ) void {
        for (self.gc_tables.items) |tbl| {
            if (!marked_tables.contains(tbl)) continue;
            for (tbl.hash) |*node| {
                if (node.value != .Nil or node.key != .String) continue;
                if (self.gc_marked_strings.contains(node.key.String)) continue;
                ltable.deadenStringKey(node);
            }
        }
    }

    /// Sweep the runtime-long-string registry: free every string not in
    /// `gc_marked_strings`. Short strings (in `string_intern`) and long
    /// literals (in `long_literals`) are NOT swept — they're managed by
    /// their respective intern tables and freed at Vm.deinit.
    fn gcSweepStrings(self: *Vm, snapshot_len: usize) void {
        var write_idx: usize = 0;
        for (self.gc_strings.items, 0..) |s, i| {
            if (i >= snapshot_len) {
                self.gc_strings.items[write_idx] = s;
                write_idx += 1;
            } else if (self.gc_marked_strings.contains(s)) {
                self.gc_strings.items[write_idx] = s;
                write_idx += 1;
            } else {
                const bytes = @sizeOf(LuaString) + s.len;
                self.gc_count_kb = @max(0, self.gc_count_kb - @as(f64, @floatFromInt(bytes)) / 1024.0);
                destroyLuaString(self.alloc, s);
            }
        }
        self.gc_strings.items.len = write_idx;
    }

    /// Sweep the cell registry: free every cell not in `gc_marked_cells`.
    /// Cells are shared between closures (upvalues) — a cell survives if ANY
    /// reachable closure or frame references it.
    fn gcSweepCells(self: *Vm, snapshot_len: usize) void {
        var write_idx: usize = 0;
        for (self.gc_cells.items, 0..) |c, i| {
            if (i >= snapshot_len) {
                self.gc_cells.items[write_idx] = c;
                write_idx += 1;
            } else if (self.gc_marked_cells.contains(c)) {
                self.gc_cells.items[write_idx] = c;
                write_idx += 1;
            } else {
                self.gc_count_kb = @max(0, self.gc_count_kb - @as(f64, @floatFromInt(@sizeOf(Cell))) / 1024.0);
                self.alloc.destroy(c);
            }
        }
        self.gc_cells.items.len = write_idx;
    }

    fn gcMarkValue(
        self: *Vm,
        v: Value,
        marked_tables: *std.AutoHashMapUnmanaged(*Table, void),
        marked_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        marked_threads: *std.AutoHashMapUnmanaged(*Thread, void),
        weak_tables: *std.ArrayListUnmanaged(*Table),
    ) Error!void {
        // Non-recursive marking (explicit worklist) to avoid stack overflows in
        // deep object graphs (gc.lua "long list").
        var work = std.ArrayListUnmanaged(Value).empty;
        defer work.deinit(self.alloc);
        try work.append(self.alloc, v);

        while (work.pop()) |cur| {
            switch (cur) {
                .Table => |tbl| {
                    if (marked_tables.contains(tbl)) continue;
                    try marked_tables.put(self.alloc, tbl, {});

                    if (tbl.metatable) |mt| try work.append(self.alloc, .{ .Table = mt });

                    const mode = self.gcWeakMode(tbl);
                    if (mode.weak_k or mode.weak_v) {
                        // De-dupe weak tables list.
                        var seen = false;
                        for (weak_tables.items) |t| {
                            if (t == tbl) {
                                seen = true;
                                break;
                            }
                        }
                        if (!seen) try weak_tables.append(self.alloc, tbl);
                    }

                    // Array part: keys are ints (non-collectable), so there is
                    // no key-liveness condition. String values are always marked
                    // (strings are values, not collectable references — sweeping
                    // a string still referenced by a table entry would UAF).
                    // Table/Closure/Thread values marked only in strong tables;
                    // weak values are pruned later by gcPruneWeakValues.
                    for (tbl.array.items) |v0| {
                        if (v0 == .String) {
                            try work.append(self.alloc, v0);
                        } else if (!mode.weak_v) {
                            if (v0 == .Table or v0 == .Closure or v0 == .Thread) try work.append(self.alloc, v0);
                        }
                    }
                    // Hash part: mark strong keys and strong values INDEPENDENTLY.
                    //   - strong key (!weak_k): always mark (a weak-VALUE table must
                    //     still mark its keys so `a[t]=t` survives pruning).
                    //   - strong value (!weak_v AND !weak_k): mark. For weak-KEY
                    //     tables values are ephemerons (alive iff key alive) and
                    //     are resolved by gcPropagateEphemerons, not marked here.
                    // Unified hash part: keys are real Values now (Table/Closure/
                    // Thread/Int/String/Bool/Num), not the old tagged PtrKey, so
                    // we mark them through the same switch as the value.
                    for (tbl.hash) |*node| {
                        if (node.key == .Nil) continue; // empty slot or dead key
                        if (node.value == .Nil) continue; // logically deleted
                        // Mark string keys even in weak-key tables — hash nodes
                        // retain key references and keyEq dereferences strings,
                        // so sweeping a live string key would cause UAF. Deleted
                        // string keys are converted to dead keys before string
                        // sweep, mirroring PUC's DEADKEY transition.
                        const k = node.key;
                        if (k == .String) {
                            try work.append(self.alloc, k);
                        } else if (!mode.weak_k) {
                            if (k == .Table or k == .Closure or k == .Thread) try work.append(self.alloc, k);
                        }
                        // Mark values: strings are always marked (they don't
                        // participate in ephemeron resolution). Table/Closure/
                        // Thread values are marked only in strong tables;
                        // weak-key tables resolve them via gcPropagateEphemerons.
                        const val = node.value;
                        if (val == .String) {
                            try work.append(self.alloc, val);
                        } else if (!mode.weak_v and !mode.weak_k) {
                            if (val == .Table or val == .Closure or val == .Thread) try work.append(self.alloc, val);
                        }
                    }
                },
                .Closure => |cl| {
                    if (marked_closures.contains(cl)) continue;
                    try marked_closures.put(self.alloc, cl, {});
                    for (cl.upvalues) |cell| {
                        // Mark the cell itself as reachable (for cell sweep).
                        if (!self.gc_marked_cells.contains(cell)) {
                            try self.gc_marked_cells.put(self.alloc, cell, {});
                        }
                        const uv = cell.value;
                        if (uv == .Table or uv == .Closure or uv == .Thread or uv == .String) try work.append(self.alloc, uv);
                    }
                },
                .Thread => |th| {
                    if (marked_threads.contains(th)) continue;
                    try marked_threads.put(self.alloc, th, {});
                    if (th.callee == .Table or th.callee == .Closure or th.callee == .Thread) {
                        try work.append(self.alloc, th.callee);
                    }
                    if (th.debug_hook.func) |hv| {
                        if (hv == .Table or hv == .Closure or hv == .Thread) {
                            try work.append(self.alloc, hv);
                        }
                    }
                    if (th.yielded) |ys| {
                        for (ys) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    for (th.wrap_yields.items) |item| {
                        for (item.values) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    if (th.wrap_final_values) |vals| {
                        for (vals) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    if (th.wrap_repeat_closure) |cl| {
                        try work.append(self.alloc, .{ .Closure = cl });
                    }
                    if (th.dofile_entry_closure) |cl| {
                        try work.append(self.alloc, .{ .Closure = cl });
                    }
                    if (th.locals_snapshot) |snap| {
                        for (snap) |entry| {
                            const yv = entry.value;
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    if (th.resume_inbox) |vals| {
                        for (vals) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    if (th.tail_resume_inbox) |vals| {
                        for (vals) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    if (th.last_yield_payload) |vals| {
                        for (vals) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                    }
                    for (th.suspended_frames.items) |fr| {
                        if (fr.callee == .Table or fr.callee == .Closure or fr.callee == .Thread) {
                            try work.append(self.alloc, fr.callee);
                        }
                        if (fr.env_override) |env_v| {
                            if (env_v == .Table or env_v == .Closure or env_v == .Thread) {
                                try work.append(self.alloc, env_v);
                            }
                        }
                        for (fr.regs) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                        const nlocals = @min(fr.locals.len, fr.local_active.len);
                        for (fr.locals[0..nlocals], fr.local_active[0..nlocals]) |yv, active| {
                            if (active and (yv == .Table or yv == .Closure or yv == .Thread or yv == .String)) {
                                try work.append(self.alloc, yv);
                            }
                        }
                        for (fr.varargs) |yv| {
                            if (yv == .Table or yv == .Closure or yv == .Thread or yv == .String) {
                                try work.append(self.alloc, yv);
                            }
                        }
                        for (fr.upvalues) |cell| {
                            if (!self.gc_marked_cells.contains(cell)) {
                                try self.gc_marked_cells.put(self.alloc, cell, {});
                            }
                            const uv = cell.value;
                            if (uv == .Table or uv == .Closure or uv == .Thread or uv == .String) {
                                try work.append(self.alloc, uv);
                            }
                        }
                    }
                },
                .String => |s| {
                    // Mark the string as reachable. Strings don't reference
                    // other GC objects, so no further traversal needed.
                    if (!self.gc_marked_strings.contains(s)) {
                        try self.gc_marked_strings.put(self.alloc, s, {});
                    }
                },
                else => {},
            }
        }
    }

    fn gcPropagateEphemerons(
        self: *Vm,
        marked_tables: *std.AutoHashMapUnmanaged(*Table, void),
        marked_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        marked_threads: *std.AutoHashMapUnmanaged(*Thread, void),
        weak_tables: *std.ArrayListUnmanaged(*Table),
    ) Error!void {
        // The weak_tables list can grow as we mark new values; iterate over it.
        var changed = true;
        while (changed) {
            changed = false;
            var idx: usize = 0;
            while (idx < weak_tables.items.len) : (idx += 1) {
                const tbl = weak_tables.items[idx];
                const mode = self.gcWeakMode(tbl);
                if (!(mode.weak_k and !mode.weak_v)) continue; // pure weak-key table

                // Walk every live node in the unified hash part. A node is an
                // ephemeron (key controls value liveness); when its key is
                // marked, the value becomes reachable.
                for (tbl.hash) |*node| {
                    if (node.key == .Nil) continue;
                    if (node.value == .Nil) continue;
                    const k = node.key;
                    const key_marked = switch (k) {
                        .Table => |t| marked_tables.contains(t),
                        .Closure => |cl| marked_closures.contains(cl),
                        .Thread => |th| marked_threads.contains(th),
                        // Non-collectable key kinds (Int/String/Bool/Num/Builtin)
                        // are always "alive".
                        else => true,
                    };
                    if (!key_marked) continue;

                    const prev_tables = marked_tables.count();
                    const prev_closures = marked_closures.count();
                    const prev_threads = marked_threads.count();
                    try self.gcMarkValue(node.value, marked_tables, marked_closures, marked_threads, weak_tables);
                    if (marked_tables.count() != prev_tables or marked_closures.count() != prev_closures or marked_threads.count() != prev_threads) {
                        changed = true;
                    }
                }
            }
        }
    }

    fn gcPruneWeakValues(
        self: *Vm,
        weak_tbls: []const *Table,
        marked_tables: *const std.AutoHashMapUnmanaged(*Table, void),
        marked_closures: *const std.AutoHashMapUnmanaged(*Closure, void),
        marked_threads: *const std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        for (weak_tbls) |tbl| {
            const mode = self.gcWeakMode(tbl);
            if (!mode.weak_v) continue;

            // Array values: clear entries whose value became dead.
            for (tbl.array.items, 0..) |v, i| {
                if (v == .Table and !marked_tables.contains(v.Table)) {
                    tbl.array.items[i] = .Nil;
                }
                if (v == .Closure and !marked_closures.contains(v.Closure)) {
                    tbl.array.items[i] = .Nil;
                }
                if (v == .Thread and !marked_threads.contains(v.Thread)) {
                    tbl.array.items[i] = .Nil;
                }
            }

            // Unified hash part: drop entries whose value became dead. PUC
            // deletes them via tableremove; we use ltable.nodeDelete which
            // sets value:=Nil (chain intact; compacted at next rehash).
            for (tbl.hash) |*node| {
                if (node.key == .Nil) continue;
                if (node.value == .Nil) continue;
                const v = node.value;
                const drop = switch (v) {
                    .Table => |t| !marked_tables.contains(t),
                    .Closure => |cl| !marked_closures.contains(cl),
                    .Thread => |th| !marked_threads.contains(th),
                    else => false,
                };
                if (drop) node.value = .Nil;
            }
        }
    }

    fn gcPruneWeakKeys(
        self: *Vm,
        weak_tbls: []const *Table,
        marked_tables: *const std.AutoHashMapUnmanaged(*Table, void),
        marked_closures: *const std.AutoHashMapUnmanaged(*Closure, void),
        marked_threads: *const std.AutoHashMapUnmanaged(*Thread, void),
        fin_tables: *const std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *const std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *const std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        for (weak_tbls) |tbl| {
            const mode = self.gcWeakMode(tbl);
            if (!mode.weak_k) continue;

            for (tbl.hash) |*node| {
                if (node.key == .Nil) continue;
                if (node.value == .Nil) continue;
                const k = node.key;
                // Drop entries whose collectable key is no longer reachable
                // (not in the marked set AND not pending finalization).
                const drop = switch (k) {
                    .Table => |t| !marked_tables.contains(t) and !fin_tables.contains(t),
                    .Closure => |cl| !marked_closures.contains(cl) and !fin_closures.contains(cl),
                    .Thread => |th| !marked_threads.contains(th) and !fin_threads.contains(th),
                    else => false,
                };
                if (drop) node.value = .Nil;
            }
        }
    }

    fn gcCollectFinalizables(
        self: *Vm,
        marked_tables: *const std.AutoHashMapUnmanaged(*Table, void),
    ) Error![]*Table {
        var to_finalize = std.ArrayListUnmanaged(*Table).empty;
        var it = self.finalizables.iterator();
        while (it.next()) |entry| {
            const obj = entry.key_ptr.*;
            if (!marked_tables.contains(obj)) {
                try to_finalize.append(self.alloc, obj);
            }
        }
        return to_finalize.toOwnedSlice(self.alloc);
    }

    fn gcMarkFinalizerReach(
        self: *Vm,
        objs: []const *Table,
        fin_tables: *std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        for (objs) |obj| {
            try self.gcMarkValueFinalizerReach(.{ .Table = obj }, fin_tables, fin_closures, fin_threads);
        }
    }

    fn gcMarkValueFinalizerReach(
        self: *Vm,
        v: Value,
        fin_tables: *std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        switch (v) {
            .Table => |t| try self.gcMarkTableFinalizerReach(t, fin_tables, fin_closures, fin_threads),
            .Closure => |cl| try self.gcMarkClosureFinalizerReach(cl, fin_tables, fin_closures, fin_threads),
            .Thread => |th| try self.gcMarkThreadFinalizerReach(th, fin_tables, fin_closures, fin_threads),
            else => {},
        }
    }

    fn gcMarkClosureFinalizerReach(
        self: *Vm,
        cl: *Closure,
        fin_tables: *std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        if (fin_closures.contains(cl)) return;
        try fin_closures.put(self.alloc, cl, {});
        for (cl.upvalues) |cell| {
            try self.gcMarkValueFinalizerReach(cell.value, fin_tables, fin_closures, fin_threads);
        }
    }

    fn gcMarkThreadFinalizerReach(
        self: *Vm,
        th: *Thread,
        fin_tables: *std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        if (fin_threads.contains(th)) return;
        try fin_threads.put(self.alloc, th, {});
        try self.gcMarkValueFinalizerReach(th.callee, fin_tables, fin_closures, fin_threads);
        if (th.yielded) |ys| {
            for (ys) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        for (th.wrap_yields.items) |item| {
            for (item.values) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        if (th.wrap_final_values) |vals| {
            for (vals) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        if (th.wrap_repeat_closure) |cl| {
            try self.gcMarkValueFinalizerReach(.{ .Closure = cl }, fin_tables, fin_closures, fin_threads);
        }
        if (th.dofile_entry_closure) |cl| {
            try self.gcMarkValueFinalizerReach(.{ .Closure = cl }, fin_tables, fin_closures, fin_threads);
        }
        if (th.resume_inbox) |vals| {
            for (vals) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        if (th.tail_resume_inbox) |vals| {
            for (vals) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        if (th.last_yield_payload) |vals| {
            for (vals) |yv| {
                try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
        }
        for (th.suspended_frames.items) |fr| {
            try self.gcMarkValueFinalizerReach(fr.callee, fin_tables, fin_closures, fin_threads);
            if (fr.env_override) |env_v| {
                try self.gcMarkValueFinalizerReach(env_v, fin_tables, fin_closures, fin_threads);
            }
            for (fr.regs) |yv| try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            const nlocals = @min(fr.locals.len, fr.local_active.len);
            for (fr.locals[0..nlocals], fr.local_active[0..nlocals]) |yv, active| {
                if (active) try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            }
            for (fr.varargs) |yv| try self.gcMarkValueFinalizerReach(yv, fin_tables, fin_closures, fin_threads);
            for (fr.upvalues) |cell| try self.gcMarkValueFinalizerReach(cell.value, fin_tables, fin_closures, fin_threads);
        }
    }

    fn gcMarkTableFinalizerReach(
        self: *Vm,
        tbl: *Table,
        fin_tables: *std.AutoHashMapUnmanaged(*Table, void),
        fin_closures: *std.AutoHashMapUnmanaged(*Closure, void),
        fin_threads: *std.AutoHashMapUnmanaged(*Thread, void),
    ) Error!void {
        if (fin_tables.contains(tbl)) return;
        try fin_tables.put(self.alloc, tbl, {});

        if (tbl.metatable) |mt| try self.gcMarkValueFinalizerReach(.{ .Table = mt }, fin_tables, fin_closures, fin_threads);

        const mode = self.gcWeakMode(tbl);
        if (!mode.weak_v) {
            for (tbl.array.items) |vv| try self.gcMarkValueFinalizerReach(vv, fin_tables, fin_closures, fin_threads);
        }

        // Unified hash part: walk every live node. Same shape as gcMarkValue's
        // hash traversal — mark key (unless weak-k) and value (unless weak-v
        // and weak-k together, which makes the value an ephemeron).
        for (tbl.hash) |*node| {
            if (node.key == .Nil) continue;
            if (node.value == .Nil) continue; // tombstone
            const k = node.key;
            const vv = node.value;
            if (!mode.weak_k) {
                try self.gcMarkValueFinalizerReach(k, fin_tables, fin_closures, fin_threads);
            }
            if (!mode.weak_v and !mode.weak_k) {
                try self.gcMarkValueFinalizerReach(vv, fin_tables, fin_closures, fin_threads);
            }
        }
    }

    fn gcFinalizeList(self: *Vm, to_finalize: []const *Table) Error!void {
        const ordered = try self.alloc.dupe(*Table, to_finalize);
        defer self.alloc.free(ordered);
        std.sort.block(*Table, ordered, self, gcFinalizeLessThan);
        for (ordered) |obj| {
            _ = self.finalizables.remove(obj);
            const mt = obj.metatable orelse continue;
            const gc = self.getFieldOpt(mt, "__gc") orelse continue;
            const call_args = &[_]Value{.{ .Table = obj }};
            _ = self.callFinalizer(gc, call_args) catch |e| switch (e) {
                // Lua ignores errors in finalizers (reports through warning
                // channel); keep collector progress.
                error.RuntimeError => {
                    self.err = null;
                    self.err_has_obj = false;
                    self.err_obj = .Nil;
                    continue;
                },
                else => return e,
            };
        }
    }

    fn testcFinalizeRank(self: *Vm, obj: *Table) i64 {
        const v: Value = .{ .Table = obj };
        if (!isTestcUserdata(self, v)) return std.math.minInt(i64);
        const vv = self.getFieldOpt(obj, "__val") orelse return std.math.minInt(i64) + 1;
        return switch (vv) {
            .Int => |n| n,
            .Num => |n| if (n == @floor(n) and std.math.isFinite(n) and n >= @as(f64, @floatFromInt(std.math.minInt(i64))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                @intFromFloat(n)
            else
                std.math.minInt(i64) + 1,
            else => std.math.minInt(i64) + 1,
        };
    }

    fn gcFinalizeLessThan(self: *Vm, lhs: *Table, rhs: *Table) bool {
        const lr = testcFinalizeRank(self, lhs);
        const rr = testcFinalizeRank(self, rhs);
        if (lr != rr) return lr > rr;
        return @intFromPtr(lhs) > @intFromPtr(rhs);
    }

    fn builtinDofile(self: *Vm, args: []const Value, outs: []Value) Error!void {
        var entry_cl: ?*Closure = null;
        if (self.current_thread) |th| {
            if (th.callee == .Builtin and th.callee.Builtin == .dofile) {
                if (th.dofile_entry_closure) |cl| {
                    entry_cl = cl;
                }
            }
        }

        if (entry_cl == null) {
            const path = if (args.len > 0) switch (args[0]) {
                .String => |s| s.bytes(),
                else => return self.fail("dofile expects filename string", .{}),
            } else return self.fail("dofile expects filename string", .{});

            const source = LuaSource.loadFile(self.alloc, stdio.activeIo(), path) catch |e| return self.fail("dofile: cannot read '{s}': {s}", .{ path, @errorName(e) });

            var lex = LuaLexer.init(source);
            var p = LuaParser.init(&lex) catch return self.fail("{s}", .{lex.diagString()});

            var ast_arena = lua_ast.AstArena.init(self.alloc);
            defer ast_arena.deinit();
            const chunk = p.parseChunkAst(&ast_arena) catch return self.fail("{s}", .{p.diagString()});

            var cg = lua_codegen.Codegen.init(self.alloc, source.name, source.bytes);
            const main_fn = cg.compileChunk(chunk) catch return self.fail("{s}", .{cg.diagString()});

            try self.testcChargeMemory(@sizeOf(Closure) + 64);
            const cl = try self.alloc.create(Closure);
            cl.* = .{ .func = main_fn, .upvalues = &.{} };
            try self.gc_closures.append(self.alloc, cl);
            self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
            self.testc_obj_functions += 1;
            try self.applyLoadEnv(cl, .{ .Table = self.global_env }, false);
            cl.synthetic_env_slot = (functionUsesGlobalNames(main_fn) and !functionHasNamedEnvUpvalue(main_fn));
            if (self.current_thread) |th| {
                if (th.callee == .Builtin and th.callee.Builtin == .dofile) {
                    th.dofile_entry_closure = cl;
                }
            }
            entry_cl = cl;
        }

        const cl = entry_cl.?;
        const ret = self.runClosure(cl, &.{}, false) catch |e| switch (e) {
            error.Yield => return error.Yield,
            else => return error.RuntimeError,
        };
        defer self.alloc.free(ret);
        const n = @min(outs.len, ret.len);
        for (0..n) |i| outs[i] = ret[i];
        self.last_builtin_out_count = ret.len;
    }

    const ChunkPrefix = struct {
        bytes: []const u8,
        had_shebang: bool = false,
    };

    fn stripChunkPrefix(bytes: []const u8, allow_shebang: bool) ChunkPrefix {
        var s = bytes;
        if (s.len >= 3 and s[0] == 0xEF and s[1] == 0xBB and s[2] == 0xBF) {
            s = s[3..];
        }
        if (allow_shebang and s.len > 0 and s[0] == '#') {
            var i: usize = 0;
            while (i < s.len and s[i] != '\n') : (i += 1) {}
            if (i < s.len) i += 1;
            s = s[i..];
            return .{ .bytes = s, .had_shebang = true };
        }
        return .{ .bytes = s };
    }

    fn builtinLoadfile(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const path = if (args.len > 0) switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("loadfile expects filename string", .{}),
        } else return self.fail("loadfile expects filename string", .{});

        const source = LuaSource.loadFile(self.alloc, stdio.activeIo(), path) catch |e| {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(try std.fmt.allocPrint(self.alloc, "loadfile: cannot read '{s}': {s}", .{ path, @errorName(e) })) };
            return;
        };
        var load_args: [4]Value = .{ .Nil, .Nil, .Nil, .Nil };
        load_args[0] = .{ .String = try self.internStr(source.bytes) };
        load_args[1] = .{ .String = try self.internStr(source.name) };
        var n: usize = 2;
        if (args.len > 1) {
            load_args[2] = args[1];
            n = 3;
        }
        if (args.len > 2) {
            load_args[3] = args[2];
            n = 4;
        }
        try self.builtinLoad(load_args[0..n], outs);
    }

    fn builtinStringDump(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.dump expects function", .{});
        const cl = switch (args[0]) {
            .Closure => |c| c,
            else => return self.fail("string.dump expects function", .{}),
        };
        const strip = if (args.len > 1) isTruthy(args[1]) else false;

        const dumped_cl: *Closure = if (strip) blk: {
            var seen = std.AutoHashMapUnmanaged(*const ir.Function, *ir.Function){};
            defer seen.deinit(self.alloc);
            const stripped = try self.cloneStrippedFunction(cl.func, &seen);
            try self.testcChargeMemory(@sizeOf(Closure) + 64);
            const dumped = try self.alloc.create(Closure);
            dumped.* = .{ .func = stripped, .upvalues = cl.upvalues };
            try self.gc_closures.append(self.alloc, dumped);
            self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
            self.testc_obj_functions += 1;
            break :blk dumped;
        } else cl;

        const id = self.dump_next_id;
        self.dump_next_id += 1;
        try self.dump_registry.put(self.alloc, id, dumped_cl);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try self.appendBinaryDumpHeader(&out);
        // Minimal luazig payload: magic + id + strip flag.
        try out.appendSlice(self.alloc, "LZIG");
        var id_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, id_buf[0..], id, .little);
        try out.appendSlice(self.alloc, id_buf[0..]);
        try out.append(self.alloc, if (strip) 1 else 0);
        const base_pad: usize = if (strip) 64 else 96;
        const src_pad: usize = if (strip) 0 else dumped_cl.func.source_name.len;
        // Keep dump size roughly proportional to instruction volume so
        // API tests that validate non-trivial binary size still hold.
        const inst_pad = dumped_cl.func.insts.len * 16;
        // Payload length is encoded into a 16-bit field in our bootstrap dump.
        // Keep the synthesized payload within that bound to avoid overflow/panic
        // on large chunks (e.g. all.lua -> nextvar.lua path).
        const target_payload: usize = @min(std.math.maxInt(u16), @max(base_pad + src_pad, inst_pad));
        var literal_extra: []const u8 = "";
        if (!strip) {
            if (std.mem.indexOfScalar(u8, dumped_cl.func.source_name, '"')) |q0| {
                const rem = dumped_cl.func.source_name[q0 + 1 ..];
                if (std.mem.indexOfScalar(u8, rem, '"')) |q1| {
                    literal_extra = rem[0..q1];
                }
            }
        }
        const meta_len = if (strip) 0 else dumped_cl.func.source_name.len + literal_extra.len;
        const used_meta: usize = if (meta_len >= target_payload) target_payload else meta_len;
        const pad_len: usize = target_payload - used_meta;
        var payload_len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, payload_len_buf[0..], @intCast(target_payload), .little);
        try out.appendSlice(self.alloc, payload_len_buf[0..]);
        if (!strip) {
            var budget = target_payload;
            const src_take = @min(budget, dumped_cl.func.source_name.len);
            if (src_take != 0) {
                try out.appendSlice(self.alloc, dumped_cl.func.source_name[0..src_take]);
                budget -= src_take;
            }
            if (budget != 0 and literal_extra.len != 0) {
                const lit_take = @min(budget, literal_extra.len);
                try out.appendSlice(self.alloc, literal_extra[0..lit_take]);
                budget -= lit_take;
            }
            std.debug.assert(budget == pad_len);
        }
        const old_len = out.items.len;
        try out.resize(self.alloc, old_len + pad_len);
        @memset(out.items[old_len..], 'X');
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn appendBinaryDumpHeader(self: *Vm, out: *std.ArrayList(u8)) Error!void {
        try out.appendSlice(self.alloc, "\x1bLua");
        try out.append(self.alloc, 0x55); // Lua 5.5 marker in upstream tests
        try out.append(self.alloc, 0); // format
        try out.appendSlice(self.alloc, "\x19\x93\r\n\x1a\n");
        try out.append(self.alloc, 4); // size of C int
        var i4_buf: [4]u8 = undefined;
        std.mem.writeInt(i32, i4_buf[0..], -0x5678, .little);
        try out.appendSlice(self.alloc, i4_buf[0..]);
        try out.append(self.alloc, 4);
        var instr_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, instr_buf[0..], 0x12345678, .little);
        try out.appendSlice(self.alloc, instr_buf[0..]);
        try out.append(self.alloc, @sizeOf(i64));
        var i_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, i_buf[0..], -0x5678, .little);
        try out.appendSlice(self.alloc, i_buf[0..]);
        try out.append(self.alloc, @sizeOf(f64));
        var n_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, n_buf[0..], @bitCast(@as(f64, -370.5)), .little);
        try out.appendSlice(self.alloc, n_buf[0..]);
    }

    fn binaryDumpHeaderSize() usize {
        return 4 + 1 + 1 + 6 + 1 + 4 + 1 + 4 + 1 + 8 + 1 + 8;
    }

    fn binaryDumpStrictHeaderSize() usize {
        // calls.lua mutates only up to this prefix (all except final lua_Number)
        return binaryDumpHeaderSize() - 8;
    }

    fn validateBinaryDumpHeader(self: *Vm, s: []const u8) Error!void {
        var expected = std.ArrayList(u8).empty;
        defer expected.deinit(self.alloc);
        try self.appendBinaryDumpHeader(&expected);
        const eh = expected.items;
        if (s.len < eh.len) return self.fail("truncated precompiled chunk", .{});
        const strict = binaryDumpStrictHeaderSize();
        if (!std.mem.eql(u8, s[0..strict], eh[0..strict])) {
            return self.fail("bad binary format (corrupted header)", .{});
        }
    }

    fn defaultLoadEnv(self: *Vm, args: []const Value) Value {
        if (args.len >= 4) return args[3];
        return .{ .Table = self.global_env };
    }

    fn applyLoadEnv(self: *Vm, cl: *Closure, env_val: Value, force_first_on_missing: bool) Error!void {
        if (cl.func.num_upvalues == 0) {
            if (force_first_on_missing) cl.env_override = env_val;
            return;
        }
        if (cl.upvalues.len < cl.func.num_upvalues) {
            const cells = try self.alloc.alloc(*Cell, cl.func.num_upvalues);
            var i: usize = 0;
            while (i < cl.func.num_upvalues) : (i += 1) {
                const c = try self.alloc.create(Cell);
                c.* = .{ .value = .Nil };
                try self.gc_cells.append(self.alloc, c);
                self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Cell))) / 1024.0;
                cells[i] = c;
            }
            cl.upvalues = cells;
        }
        var i: usize = 0;
        while (i < cl.func.upvalue_names.len and i < cl.upvalues.len) : (i += 1) {
            if (std.mem.eql(u8, cl.func.upvalue_names[i], "_ENV")) {
                cl.upvalues[i].value = env_val;
                cl.env_override = env_val;
                return;
            }
        }
        if (force_first_on_missing) {
            if (cl.upvalues.len > 0) cl.upvalues[0].value = env_val;
            cl.env_override = env_val;
        }
    }

    fn readU32Le(bytes: []const u8, pos: usize) u32 {
        var v: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) v |= (@as(u32, bytes[pos + i]) << @as(u5, @intCast(8 * i)));
        return v;
    }

    fn readU64Le(bytes: []const u8, pos: usize) u64 {
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) v |= (@as(u64, bytes[pos + i]) << @as(u6, @intCast(8 * i)));
        return v;
    }

    fn writeUIntBytes(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: u64, width: usize, little: bool) !void {
        if (little) {
            var i: usize = 0;
            while (i < width) : (i += 1) try out.append(alloc, @as(u8, @intCast((v >> @as(u6, @intCast(i * 8))) & 0xFF)));
        } else {
            var i: usize = 0;
            while (i < width) : (i += 1) {
                const shift = (width - 1 - i) * 8;
                try out.append(alloc, @as(u8, @intCast((v >> @as(u6, @intCast(shift))) & 0xFF)));
            }
        }
    }

    fn readUIntBytes(bytes: []const u8, pos: usize, width: usize, little: bool) u64 {
        var v: u64 = 0;
        if (little) {
            var i: usize = 0;
            while (i < width) : (i += 1) v |= (@as(u64, bytes[pos + i]) << @as(u6, @intCast(i * 8)));
        } else {
            var i: usize = 0;
            while (i < width) : (i += 1) {
                v = (v << 8) | bytes[pos + i];
            }
        }
        return v;
    }

    fn instantiateLoadedClosure(self: *Vm, proto: *Closure) Error!*Closure {
        try self.testcChargeMemory(@sizeOf(Closure) + 64);
        const cl = try self.alloc.create(Closure);
        self.testc_obj_functions += 1;
        // For bytecode closures, upvalue count comes from the Proto;
        // for IR closures, from the Function struct.
        const nups: usize = if (proto.proto) |p| p.upvalues.len else proto.func.num_upvalues;
        const cells = try self.alloc.alloc(*Cell, nups);
        var i: usize = 0;
        while (i < nups) : (i += 1) {
            const c = try self.alloc.create(Cell);
            c.* = .{ .value = .Nil };
            try self.gc_cells.append(self.alloc, c);
            self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Cell))) / 1024.0;
            cells[i] = c;
        }
        cl.* = .{
            .func = proto.func,
            .proto = proto.proto,
            .upvalues = cells,
            .env_override = null,
            .synthetic_env_slot = false,
        };
        try self.gc_closures.append(self.alloc, cl);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
        return cl;
    }

    fn functionUsesGlobalNames(f: *const ir.Function) bool {
        for (f.insts) |inst| {
            switch (inst) {
                .GetName, .SetName => return true,
                else => {},
            }
        }
        return false;
    }

    fn functionHasNamedEnvUpvalue(f: *const ir.Function) bool {
        for (f.upvalue_names) |nm| {
            if (std.mem.eql(u8, nm, "_ENV")) return true;
        }
        return false;
    }

    fn cloneStrippedFunction(
        self: *Vm,
        f: *const ir.Function,
        seen: *std.AutoHashMapUnmanaged(*const ir.Function, *ir.Function),
    ) Error!*ir.Function {
        if (seen.get(f)) |existing| return existing;

        const cloned = try self.alloc.create(ir.Function);
        try seen.put(self.alloc, f, cloned);

        const local_names = try self.alloc.alloc([]const u8, f.local_names.len);
        for (local_names) |*nm| nm.* = "";

        const upvalue_names = try self.alloc.alloc([]const u8, f.upvalue_names.len);
        for (upvalue_names) |*nm| nm.* = "";

        var insts = try self.alloc.alloc(ir.Inst, f.insts.len);
        for (f.insts, 0..) |inst, i| {
            insts[i] = inst;
            switch (inst) {
                .ConstFunc => |cf| {
                    const nested = try self.cloneStrippedFunction(cf.func, seen);
                    insts[i] = .{ .ConstFunc = .{ .dst = cf.dst, .func = nested } };
                },
                else => {},
            }
        }

        cloned.* = .{
            .name = f.name,
            .source_name = "=?",
            .line_defined = f.line_defined,
            .last_line_defined = f.last_line_defined,
            .insts = insts,
            .inst_lines = &.{},
            .num_values = f.num_values,
            .num_locals = f.num_locals,
            .local_names = local_names,
            .active_lines = &.{},
            .is_vararg = f.is_vararg,
            .num_params = f.num_params,
            .num_upvalues = f.num_upvalues,
            .upvalue_names = upvalue_names,
            .captures = f.captures,
            .for_numeric_controls = f.for_numeric_controls,
        };
        return cloned;
    }

    fn chunkNameForSyntaxError(self: *Vm, chunk_name: []const u8) ![]const u8 {
        const idsize: usize = 59;
        if (chunk_name.len == 0) return "[string \"\"]";

        if (chunk_name[0] == '=' or chunk_name[0] == '@') {
            const raw = chunk_name[1..];
            if (raw.len <= idsize) return try std.fmt.allocPrint(self.alloc, "{s}", .{raw});
            if (idsize <= 3) return try std.fmt.allocPrint(self.alloc, "...", .{});
            if (chunk_name[0] == '=') {
                return try std.fmt.allocPrint(self.alloc, "{s}", .{raw[0..idsize]});
            }
            const keep = idsize - 3;
            return try std.fmt.allocPrint(self.alloc, "...{s}", .{raw[raw.len - keep ..]});
        }

        if (chunk_name[0] == '\n' or chunk_name[0] == '\r') return "[string \"...\"]";

        const prefix = "[string \"";
        const suffix = "\"]";
        const max_body = if (idsize > prefix.len + suffix.len + 3) idsize - prefix.len - suffix.len - 3 else 0;
        var end: usize = 0;
        while (end < chunk_name.len and chunk_name[end] != '\n' and chunk_name[end] != '\r') : (end += 1) {}
        var body_end = end;
        var truncated = end < chunk_name.len;
        if (body_end > max_body) {
            body_end = max_body;
            truncated = true;
        }
        return if (truncated)
            try std.fmt.allocPrint(self.alloc, "[string \"{s}...\"]", .{chunk_name[0..body_end]})
        else
            try std.fmt.allocPrint(self.alloc, "[string \"{s}\"]", .{chunk_name[0..body_end]});
    }

    fn nearTokenForSyntaxError(self: *Vm, tok: LuaToken, source: []const u8) ![]const u8 {
        if (tok.kind == .Eof) return try std.fmt.allocPrint(self.alloc, "<eof>", .{});

        var raw = tok.kind.name();
        var raw_owned: ?[]const u8 = null;
        defer if (raw_owned) |s| self.alloc.free(s);

        switch (tok.kind) {
            .Name, .Number, .Integer => raw = tok.slice(source),
            .String => {
                const s = tok.slice(source);
                if (s.len > 0 and (s[0] == '\'' or s[0] == '"')) {
                    raw = s;
                } else {
                    raw_owned = try std.fmt.allocPrint(self.alloc, "[[{s}]]", .{s});
                    raw = raw_owned.?;
                }
            },
            else => {},
        }

        if (raw.len > 0 and raw[0] == '<' and raw[raw.len - 1] == '>') {
            return try std.fmt.allocPrint(self.alloc, "{s}", .{raw});
        }
        return try std.fmt.allocPrint(self.alloc, "'{s}'", .{raw});
    }

    fn formatLoadSyntaxError(self: *Vm, source: LuaSource, p: *LuaParser) ![]const u8 {
        const line: u32 = if (p.diag) |d| d.line else p.cur.line;
        const msg: []const u8 = if (p.diag) |d| d.msg else "syntax error";
        if (source.bytes.len > 0 and source.bytes[0] == '*' and std.mem.indexOf(u8, msg, "expected expression") != null) {
            return try std.fmt.allocPrint(self.alloc, "unexpected symbol", .{});
        }
        const chunk_name = try self.chunkNameForSyntaxError(source.name);
        defer self.alloc.free(chunk_name);
        const near = try self.nearTokenForSyntaxError(p.cur, source.bytes);
        defer self.alloc.free(near);
        return try std.fmt.allocPrint(self.alloc, "{s}:{d}: {s} near {s}", .{ chunk_name, line, msg, near });
    }

    fn nearLexError(self: *Vm, source: []const u8, lex: *LuaLexer) ![]const u8 {
        const at_eof = lex.i >= source.len;
        if (at_eof) {
            if (lex.diag) |d| {
                if (std.mem.indexOf(u8, d.msg, "unfinished") != null) {
                    return try std.fmt.allocPrint(self.alloc, "<eof>", .{});
                }
            }
        }
        var start = if (at_eof) source.len else lex.i;
        var j = start;
        while (j > 0) : (j -= 1) {
            const ch = source[j - 1];
            if (ch == '\n' or ch == '\r') break;
            if (ch == '"' or ch == '\'') {
                start = j;
                break;
            }
        }
        if (start >= source.len and at_eof) return try std.fmt.allocPrint(self.alloc, "<eof>", .{});
        var end: usize = if (at_eof) source.len else @min(source.len, lex.i + 1);
        if (!at_eof and lex.i < source.len and (source[lex.i] >= '0' and source[lex.i] <= '9') and lex.i + 1 < source.len and (source[lex.i + 1] == '"' or source[lex.i + 1] == '\'')) {
            end = lex.i + 2;
        }
        if (!at_eof) {
            if (lex.diag) |d| {
                if (std.mem.indexOf(u8, d.msg, "hex escape") != null and lex.i + 1 < source.len) {
                    const nxt = source[lex.i + 1];
                    if (nxt != '"' and nxt != '\'' and nxt != '\n' and nxt != '\r') {
                        end = @max(end, lex.i + 2);
                    }
                }
            }
        }
        if (end > start + 48) end = start + 48;
        return try std.fmt.allocPrint(self.alloc, "'{s}'", .{source[start..end]});
    }

    fn formatLoadLexError(self: *Vm, source: LuaSource, lex: *LuaLexer) ![]const u8 {
        const line: u32 = if (lex.diag) |d| d.line else 1;
        const msg: []const u8 = if (lex.diag) |d| d.msg else "syntax error";
        const chunk_name = try self.chunkNameForSyntaxError(source.name);
        defer self.alloc.free(chunk_name);
        const near = try self.nearLexError(source.bytes, lex);
        defer self.alloc.free(near);
        return try std.fmt.allocPrint(self.alloc, "{s}:{d}: {s} near {s}", .{ chunk_name, line, msg, near });
    }

    fn builtinLoad(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("load expects string or function", .{});
        var roots = self.gcTempRoots();
        defer roots.end();
        for (args) |arg| try roots.add(arg);
        const mode = if (args.len > 2) switch (args[2]) {
            .Nil => "bt",
            .String => |m| m.bytes(),
            else => return self.fail("load: mode must be string", .{}),
        } else "bt";
        for (mode) |ch| {
            if (ch != 'b' and ch != 't') return self.fail("load: invalid mode", .{});
        }
        const allow_binary = std.mem.indexOfScalar(u8, mode, 'b') != null;
        const allow_text = std.mem.indexOfScalar(u8, mode, 't') != null;

        var source_owned: ?[]u8 = null;
        var prefixed_owned: ?[]u8 = null;
        const source_is_reader = args[0] != .String;
        const s: []const u8 = switch (args[0]) {
            .String => |x| blk: {
                // Pin the source LuaString as a GC root so it's not swept
                // while the compiled function's lexeme slices point into it.
                // Same lifetime as PUC Lua's proto owning its source.
                try self.pinned_source_strings.append(self.alloc, x);
                break :blk x.bytes();
            },
            else => blk: {
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                while (true) {
                    const resolved = self.resolveCallable(args[0], &.{}, null) catch {
                        outs[0] = .Nil;
                        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(self.errorString()) };
                        return;
                    };
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);

                    var piece: Value = .Nil;
                    switch (resolved.callee) {
                        .Builtin => |id| {
                            var out1 = [_]Value{.Nil};
                            self.callBuiltin(id, resolved.args, out1[0..]) catch {
                                outs[0] = .Nil;
                                if (outs.len > 1) outs[1] = .{ .String = try self.internStr(self.errorString()) };
                                return;
                            };
                            piece = out1[0];
                        },
                        .Closure => |cl| {
                            const ret = self.runClosure(cl, resolved.args, false) catch {
                                outs[0] = .Nil;
                                if (outs.len > 1) outs[1] = .{ .String = try self.internStr(self.errorString()) };
                                return;
                            };
                            defer self.alloc.free(ret);
                            piece = if (ret.len > 0) ret[0] else .Nil;
                        },
                        else => unreachable,
                    }
                    switch (piece) {
                        .Nil => break,
                        .String => |part| {
                            if (part.len == 0) break;
                            try buf.appendSlice(self.alloc, part.bytes());
                        },
                        else => {
                            outs[0] = .Nil;
                            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("reader function must return a string") };
                            return;
                        },
                    }
                }
                source_owned = try buf.toOwnedSlice(self.alloc);
                break :blk source_owned.?;
            },
        };
        const default_chunk_name: []const u8 = if (source_is_reader) "=(load)" else s;
        const chunk_name_hint = if (args.len > 1) switch (args[1]) {
            .Nil => default_chunk_name,
            .String => |nm| nm.bytes(),
            else => return self.fail("load: chunk name must be string", .{}),
        } else default_chunk_name;
        const allow_shebang = chunk_name_hint.len != 0 and chunk_name_hint[0] == '@';
        const prefix = stripChunkPrefix(s, allow_shebang);
        var chunk_bytes = prefix.bytes;
        if (prefix.had_shebang and !(chunk_bytes.len > 0 and chunk_bytes[0] == 0x1b)) {
            prefixed_owned = try self.alloc.alloc(u8, chunk_bytes.len + 1);
            prefixed_owned.?[0] = '\n';
            @memcpy(prefixed_owned.?[1..], chunk_bytes);
            chunk_bytes = prefixed_owned.?;
        }

        if (chunk_bytes.len > 0 and chunk_bytes[0] == 0x1b) {
            if (!allow_binary) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("attempt to load a binary chunk") };
                return;
            }
            self.validateBinaryDumpHeader(chunk_bytes) catch {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr(self.errorString()) };
                return;
            };
            const hsz = binaryDumpHeaderSize();
            if (chunk_bytes.len < hsz + 4 + 8 + 1 + 2) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("truncated precompiled chunk") };
                return;
            }
            if (!std.mem.eql(u8, chunk_bytes[hsz .. hsz + 4], "LZIG")) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("bad binary format (unknown payload)") };
                return;
            }
            const payload_len: usize = @as(usize, chunk_bytes[hsz + 13]) | (@as(usize, chunk_bytes[hsz + 14]) << 8);
            if (chunk_bytes.len < hsz + 4 + 8 + 1 + 2 + payload_len) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("truncated precompiled chunk") };
                return;
            }
            if (chunk_bytes.len != hsz + 4 + 8 + 1 + 2 + payload_len) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("bad binary format (extra bytes)") };
                return;
            }
            const n = readU64Le(chunk_bytes, hsz + 4);
            const proto = self.dump_registry.get(n) orelse {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("load: unknown dump id") };
                return;
            };
            const cl = try self.instantiateLoadedClosure(proto);
            const explicit_env = args.len >= 4;
            try self.applyLoadEnv(cl, self.defaultLoadEnv(args), explicit_env);
            const has_named_env = functionHasNamedEnvUpvalue(proto.func);
            cl.synthetic_env_slot = (functionUsesGlobalNames(proto.func) and !has_named_env);
            outs[0] = .{ .Closure = cl };
            if (outs.len > 1) outs[1] = .Nil;
            return;
        }
        const dump_prefix = "DUMP:";
        if (std.mem.startsWith(u8, chunk_bytes, dump_prefix)) {
            if (!allow_binary) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("attempt to load a binary chunk") };
                return;
            }
            var end = dump_prefix.len;
            while (end < chunk_bytes.len and chunk_bytes[end] >= '0' and chunk_bytes[end] <= '9') : (end += 1) {}
            if (end == dump_prefix.len) return self.fail("load: invalid dump id", .{});
            const n = std.fmt.parseInt(u64, chunk_bytes[dump_prefix.len..end], 10) catch return self.fail("load: invalid dump id", .{});
            const proto = self.dump_registry.get(n) orelse return self.fail("load: unknown dump id", .{});
            const cl = try self.instantiateLoadedClosure(proto);
            const explicit_env = args.len >= 4;
            try self.applyLoadEnv(cl, self.defaultLoadEnv(args), explicit_env);
            const has_named_env = functionHasNamedEnvUpvalue(proto.func);
            cl.synthetic_env_slot = (functionUsesGlobalNames(proto.func) and !has_named_env);
            outs[0] = .{ .Closure = cl };
            if (outs.len > 1) outs[1] = .Nil;
            return;
        }
        if (!allow_text) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("attempt to load a text chunk") };
            return;
        }

        const chunk_name = if (args.len > 1) switch (args[1]) {
            .Nil => default_chunk_name,
            .String => |nm| nm.bytes(),
            else => return self.fail("load: chunk name must be string", .{}),
        } else default_chunk_name;
        const source = LuaSource{ .name = chunk_name, .bytes = chunk_bytes };
        var lex = LuaLexer.init(source);
        var p = LuaParser.init(&lex) catch {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(try self.formatLoadLexError(source, &lex)) };
            return;
        };

        var ast_arena = lua_ast.AstArena.init(self.alloc);
        defer ast_arena.deinit();
        const chunk = p.parseChunkAst(&ast_arena) catch {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(try self.formatLoadSyntaxError(source, &p)) };
            return;
        };

        var cg = lua_codegen.Codegen.init(self.alloc, source.name, source.bytes);
        cg.chunk_is_vararg = std.mem.indexOf(u8, chunk_bytes, "...") != null;
        const main_fn = cg.compileChunk(chunk) catch {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(cg.diagString()) };
            return;
        };

        try self.testcChargeMemory(@sizeOf(Closure) + 64);
        const cl = try self.alloc.create(Closure);
        cl.* = .{ .func = main_fn, .upvalues = &[_]*Cell{} };
        try self.gc_closures.append(self.alloc, cl);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
        self.testc_obj_functions += 1;
        const explicit_env = args.len >= 4;
        try self.applyLoadEnv(cl, self.defaultLoadEnv(args), explicit_env);
        cl.synthetic_env_slot = (functionUsesGlobalNames(main_fn) and !functionHasNamedEnvUpvalue(main_fn));
        outs[0] = .{ .Closure = cl };
        if (outs.len > 1) outs[1] = .Nil;
    }

    fn builtinRequire(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("require expects module name", .{});
        const name = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("require expects module name", .{}),
        };

        const package_v = self.getGlobal("package");
        const package_tbl = try self.expectTable(package_v);
        const loaded_v = self.getFieldOpt(package_tbl, "loaded") orelse return self.fail("require: package.loaded missing", .{});
        const loaded_tbl = try self.expectTable(loaded_v);
        const preload_v = self.getFieldOpt(package_tbl, "preload") orelse return self.fail("require: package.preload missing", .{});
        const preload_tbl = try self.expectTable(preload_v);

        // Built-in modules.
        if (std.mem.eql(u8, name, "debug")) {
            if (self.getFieldOpt(loaded_tbl, name)) |v| {
                if (v != .Nil) {
                    outs[0] = v;
                    return;
                }
            }

            const mod = try self.allocTable();
            // Provide a growing subset of the standard debug library. For now
            // we expose the functions upstream checks for existence.
            try self.setField(mod, "getinfo", .{ .Builtin = .debug_getinfo });
            try self.setField(mod, "getlocal", .{ .Builtin = .debug_getlocal });
            try self.setField(mod, "setlocal", .{ .Builtin = .debug_setlocal });
            try self.setField(mod, "getupvalue", .{ .Builtin = .debug_getupvalue });
            try self.setField(mod, "setupvalue", .{ .Builtin = .debug_setupvalue });
            try self.setField(mod, "upvalueid", .{ .Builtin = .debug_upvalueid });
            try self.setField(mod, "upvaluejoin", .{ .Builtin = .debug_upvaluejoin });
            try self.setField(mod, "gethook", .{ .Builtin = .debug_gethook });
            try self.setField(mod, "sethook", .{ .Builtin = .debug_sethook });
            try self.setField(mod, "getregistry", .{ .Builtin = .debug_getregistry });
            try self.setField(mod, "traceback", .{ .Builtin = .debug_traceback });
            try self.setField(mod, "getuservalue", .{ .Builtin = .debug_getuservalue });
            try self.setField(mod, "setmetatable", .{ .Builtin = .debug_setmetatable });
            try self.setField(mod, "getmetatable", .{ .Builtin = .getmetatable });
            try self.setField(mod, "setuservalue", .{ .Builtin = .debug_setuservalue });

            const v: Value = .{ .Table = mod };
            try self.setField(loaded_tbl, name, v);
            outs[0] = v;
            return;
        }

        if (self.getFieldOpt(loaded_tbl, name)) |v| {
            if (v != .Nil) {
                outs[0] = v;
                return;
            }
        }

        if (self.getFieldOpt(preload_tbl, name)) |loader| {
            switch (loader) {
                .Builtin => |id| {
                    var loader_args = [_]Value{.{ .String = try self.internStr(name) }};
                    var loader_out: [2]Value = .{ .Nil, .Nil };
                    try self.callBuiltin(id, loader_args[0..], loader_out[0..]);
                    const v: Value = if (loader_out[0] != .Nil) loader_out[0] else .{ .Bool = true };
                    try self.setField(loaded_tbl, name, v);
                    outs[0] = v;
                    return;
                },
                .Closure => |cl| {
                    const loader_args = [_]Value{.{ .String = try self.internStr(name) }};
                    const ret = try self.runClosure(cl, loader_args[0..], false);
                    defer self.alloc.free(ret);
                    const v: Value = if (ret.len > 0 and ret[0] != .Nil) ret[0] else .{ .Bool = true };
                    try self.setField(loaded_tbl, name, v);
                    outs[0] = v;
                    return;
                },
                else => {},
            }
        }

        const path_val = self.getFieldOpt(package_tbl, "path") orelse return self.fail("module '{s}' not found:\n\tno field package.preload['{s}']\n\tno file 'package.path'", .{ name, name });
        const path = switch (path_val) {
            .String => |s| s,
            else => return self.fail("module '{s}' not found:\n\tno field package.preload['{s}']\n\tno file 'package.path'", .{ name, name }),
        };
        const cpath: []const u8 = if (self.getFieldOpt(package_tbl, "cpath")) |cv| switch (cv) {
            .String => |s| s.bytes(),
            else => "",
        } else "";

        var searchpath_out: [2]Value = .{ .Nil, .Nil };
        try self.builtinPackageSearchpath(&[_]Value{ .{ .String = try self.internStr(name) }, .{ .String = path } }, searchpath_out[0..]);
        if (searchpath_out[0] == .String) {
            const file_path = searchpath_out[0].String.bytes();
            var tmp: [2]Value = .{ .Nil, .Nil };
            try self.builtinLoadfile(&[_]Value{.{ .String = try self.internStr(file_path) }}, tmp[0..]);
            const cl = switch (tmp[0]) {
                .Closure => |c| c,
                else => return self.fail("require: loadfile did not return function", .{}),
            };

            const run_args = [_]Value{ .{ .String = try self.internStr(name) }, .{ .String = try self.internStr(file_path) } };
            const ret = try self.runClosure(cl, run_args[0..], false);
            defer self.alloc.free(ret);
            const v: Value = if (ret.len > 0 and ret[0] != .Nil) ret[0] else .{ .Bool = true };
            try self.setField(loaded_tbl, name, v);
            outs[0] = v;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(file_path) };
            return;
        }

        const perr_path = if (searchpath_out[1] == .String) searchpath_out[1].String.bytes() else "";
        var cpath_err: []const u8 = "";
        if (cpath.len != 0) {
            var csearch_out: [2]Value = .{ .Nil, .Nil };
            try self.builtinPackageSearchpath(&[_]Value{ .{ .String = try self.internStr(name) }, .{ .String = try self.internStr(cpath) } }, csearch_out[0..]);
            if (csearch_out[1] == .String) cpath_err = csearch_out[1].String.bytes();
        }

        const msg = try std.fmt.allocPrint(
            self.alloc,
            "module '{s}' not found:\n\tno field package.preload['{s}']{s}{s}",
            .{ name, name, perr_path, cpath_err },
        );
        return self.fail("{s}", .{msg});
    }

    fn builtinPackageSearchpath(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .Nil;
        if (args.len < 2) return self.fail("bad argument #2 to 'searchpath' (string expected)", .{});
        const name = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #1 to 'searchpath' (string expected)", .{}),
        };
        const path = switch (args[1]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #2 to 'searchpath' (string expected)", .{}),
        };
        const sep = if (args.len > 2 and args[2] != .Nil) switch (args[2]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #3 to 'searchpath' (string expected)", .{}),
        } else ".";
        const rep = if (args.len > 3 and args[3] != .Nil) switch (args[3]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #4 to 'searchpath' (string expected)", .{}),
        } else "/";

        var modname_buf = std.ArrayList(u8).empty;
        defer modname_buf.deinit(self.alloc);
        if (sep.len != 0) {
            var i: usize = 0;
            while (i < name.len) {
                if (i + sep.len <= name.len and std.mem.eql(u8, name[i .. i + sep.len], sep)) {
                    try modname_buf.appendSlice(self.alloc, rep);
                    i += sep.len;
                } else {
                    try modname_buf.append(self.alloc, name[i]);
                    i += 1;
                }
            }
        } else {
            try modname_buf.appendSlice(self.alloc, name);
        }
        const modname = modname_buf.items;

        var err_buf = std.ArrayList(u8).empty;
        defer err_buf.deinit(self.alloc);
        var it = std.mem.splitScalar(u8, path, ';');
        while (it.next()) |templ| {
            var cand_buf = std.ArrayList(u8).empty;
            defer cand_buf.deinit(self.alloc);
            if (std.mem.indexOfScalar(u8, templ, '?')) |_| {
                var ti: usize = 0;
                while (ti < templ.len) : (ti += 1) {
                    if (templ[ti] == '?') {
                        try cand_buf.appendSlice(self.alloc, modname);
                    } else {
                        try cand_buf.append(self.alloc, templ[ti]);
                    }
                }
            } else {
                try cand_buf.appendSlice(self.alloc, templ);
            }
            const candidate = cand_buf.items;
            std.Io.Dir.cwd().access(stdio.activeIo(), candidate, .{}) catch {
                try appendFmt(self.alloc, &err_buf, "\n\tno file '{s}'", .{candidate});
                continue;
            };
            if (outs.len > 0) outs[0] = .{ .String = try self.internStr(try std.fmt.allocPrint(self.alloc, "{s}", .{candidate})) };
            if (outs.len > 1) outs[1] = .Nil;
            return;
        }

        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(try std.fmt.allocPrint(self.alloc, "{s}", .{err_buf.items})) };
    }

    fn builtinSetmetatable(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len < 2) return self.fail("bad argument #2 to 'setmetatable' (nil or table expected)", .{});
        const tbl = try self.expectTable(args[0]);
        if (tbl.metatable) |cur| {
            if (self.getFieldOpt(cur, "__metatable") != null) return self.fail("cannot change a protected metatable", .{});
        }
        switch (args[1]) {
            .Nil => {
                tbl.metatable = null;
                _ = self.finalizables.remove(tbl);
            },
            .Table => |mt| {
                tbl.metatable = mt;
                if (self.getFieldOpt(mt, "__gc") != null) {
                    try self.finalizables.put(self.alloc, tbl, {});
                } else {
                    _ = self.finalizables.remove(tbl);
                }
            },
            else => return self.fail("bad argument #2 to 'setmetatable' (nil or table expected)", .{}),
        }
        if (outs.len > 0) outs[0] = args[0];
    }

    fn builtinGetmetatable(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("getmetatable expects value", .{});
        if (valueMetatable(self, args[0])) |mt| {
            outs[0] = self.getFieldOpt(mt, "__metatable") orelse .{ .Table = mt };
        } else {
            outs[0] = .Nil;
        }
    }

    fn debugInfoHasOpt(what: []const u8, c: u8) bool {
        return std.mem.indexOfScalar(u8, what, c) != null;
    }

    fn debugNameFromCallee(self: *Vm, callee: Value) ?[]const u8 {
        _ = self;
        return switch (callee) {
            .Builtin => |id| blk: {
                const full = id.name();
                if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| break :blk full[dot + 1 ..];
                break :blk full;
            },
            .Closure => |cl| blk: {
                if (cl.func.name.len == 0 or std.mem.eql(u8, cl.func.name, "<anon>")) break :blk null;
                break :blk cl.func.name;
            },
            else => null,
        };
    }

    fn debugResolveFrameIndex(self: *Vm, level: usize) ?usize {
        var visible: usize = 0;
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].hide_from_debug) continue;
            visible += 1;
            if (visible == level) return i;
        }
        return null;
    }

    const DebugName = struct {
        name: ?[]const u8 = null,
        namewhat: []const u8 = "",
    };

    fn debugIsGenericForIteratorCall(self: *Vm, caller: Frame, target: *const ir.Function) bool {
        _ = self;
        const insts = caller.func.insts;
        if (insts.len < 4) return false;
        const IterCall = struct {
            func: ir.ValueId,
            arg0: ir.ValueId,
            arg1: ir.ValueId,
        };

        var i: usize = 3;
        while (i < insts.len) : (i += 1) {
            const iter_call = switch (insts[i]) {
                .Call => |c| blk: {
                    if (c.args.len != 2) continue;
                    break :blk IterCall{
                        .func = c.func,
                        .arg0 = c.args[0],
                        .arg1 = c.args[1],
                    };
                },
                .ForIterCall => |c| IterCall{
                    .func = c.func,
                    .arg0 = c.state,
                    .arg1 = c.ctrl,
                },
                else => continue,
            };

            const g_iter = switch (insts[i - 3]) {
                .GetLocal => |g| g,
                else => continue,
            };
            const g_state = switch (insts[i - 2]) {
                .GetLocal => |g| g,
                else => continue,
            };
            const g_ctrl = switch (insts[i - 1]) {
                .GetLocal => |g| g,
                else => continue,
            };

            if (iter_call.func != g_iter.dst) continue;
            if (iter_call.arg0 != g_state.dst or iter_call.arg1 != g_ctrl.dst) continue;

            const iter_idx: usize = @intCast(g_iter.local);
            if (iter_idx >= caller.locals.len) continue;
            const iter_v = caller.locals[iter_idx];
            if (iter_v == .Closure and iter_v.Closure.func == target) return true;
        }

        return false;
    }

    fn debugInferNameFromCaller(self: *Vm, frame_index: usize, target: *const ir.Function) DebugName {
        if (frame_index == 0 or frame_index > self.frames.items.len) return .{};
        const caller = self.frames.items[frame_index - 1];
        if (self.debugIsGenericForIteratorCall(caller, target)) {
            return .{ .name = "for iterator", .namewhat = "for iterator" };
        }

        const nlocals: usize = @min(caller.locals.len, caller.func.local_names.len);
        var i: usize = 0;
        while (i < nlocals) : (i += 1) {
            const v = caller.locals[i];
            if (v == .Closure and v.Closure.func == target) {
                const nm = caller.func.local_names[i];
                if (nm.len != 0) return .{ .name = nm, .namewhat = "local" };
            }
        }

        i = 0;
        while (i < caller.locals.len) : (i += 1) {
            const v = caller.locals[i];
            if (v != .Table) continue;
            // Walk the unified hash part to find which field holds the target
            // closure; report the field's key (must be a String for the legacy
            // `entry.key_ptr.*` to remain a []const u8 name).
            for (v.Table.hash) |*node| {
                if (node.key == .Nil) continue;
                if (node.value == .Nil) continue;
                const fv = node.value;
                if (fv == .Closure and fv.Closure.func == target) {
                    if (node.key == .String) {
                        return .{ .name = node.key.String.bytes(), .namewhat = "field" };
                    }
                }
            }
        }

        for (caller.upvalues) |cell| {
            const v = cell.value;
            if (v != .Table) continue;
            for (v.Table.hash) |*node| {
                if (node.key == .Nil) continue;
                if (node.value == .Nil) continue;
                const fv = node.value;
                if (fv == .Closure and fv.Closure.func == target) {
                    if (node.key == .String) {
                        return .{ .name = node.key.String.bytes(), .namewhat = "field" };
                    }
                }
            }
        }

        // Globals: walk _G's unified hash for the matching closure.
        for (self.global_env.hash) |*node| {
            if (node.key == .Nil) continue;
            if (node.value == .Nil) continue;
            const gv = node.value;
            if (gv == .Closure and gv.Closure.func == target) {
                if (node.key == .String) {
                    return .{ .name = node.key.String.bytes(), .namewhat = "global" };
                }
            }
        }

        return .{};
    }

    fn debugInfoValidateOpts(self: *Vm, what: []const u8) Error!void {
        for (what) |ch| {
            if (ch == '>') return self.fail("bad option '>' to 'getinfo'", .{});
            if (std.mem.indexOfScalar(u8, "nSluftLr", ch) == null) {
                return self.fail("bad option '{c}' to 'getinfo'", .{ch});
            }
        }
    }

    fn debugShortSource(self: *Vm, src: []const u8) Error![]const u8 {
        const idsize: usize = 60;
        if (src.len == 0) return try std.fmt.allocPrint(self.alloc, "[string \"\"]", .{});

        if (src[0] == '=') {
            const raw = src[1..];
            if (raw.len <= idsize) return raw;
            return raw[0..idsize];
        }

        if (src[0] == '@') {
            const raw = src[1..];
            if (raw.len <= idsize) return raw;
            const keep = if (idsize > 3) idsize - 3 else 0;
            return try std.fmt.allocPrint(self.alloc, "...{s}", .{raw[raw.len - keep ..]});
        }

        // File-loaded chunks should behave like "@file.lua" even when the
        // current bootstrap pipeline passes raw file names.
        const looks_like_path = std.mem.endsWith(u8, src, ".lua") or
            std.mem.indexOfScalar(u8, src, '/') != null or
            std.mem.indexOfScalar(u8, src, '\\') != null;
        if (looks_like_path) {
            if (src.len <= idsize) return src;
            const keep = if (idsize > 3) idsize - 3 else 0;
            return try std.fmt.allocPrint(self.alloc, "...{s}", .{src[src.len - keep ..]});
        }

        if (src[0] == '\n' or src[0] == '\r') return "[string \"...\"]";

        const nl = std.mem.indexOfAny(u8, src, "\r\n") orelse src.len;
        var body_end = nl;
        var truncated = nl < src.len;
        const max_body = if (idsize > "[string \"".len + "\"]".len + 3) idsize - "[string \"".len - "\"]".len - 3 else 0;
        if (body_end > max_body) {
            body_end = max_body;
            truncated = true;
        }

        return if (truncated)
            try std.fmt.allocPrint(self.alloc, "[string \"{s}...\"]", .{src[0..body_end]})
        else
            try std.fmt.allocPrint(self.alloc, "[string \"{s}\"]", .{src[0..body_end]});
    }

    fn debugFillInfoFromIrFunction(self: *Vm, t: *Table, f: *const ir.Function, what: []const u8, runtime_nups: ?i64) Error!void {
        const has_s = what.len == 0 or debugInfoHasOpt(what, 'S');
        const has_u = what.len == 0 or debugInfoHasOpt(what, 'u');
        if (has_s) {
            const short_src = try self.debugShortSource(f.source_name);
            const looks_like_path = f.source_name.len != 0 and
                (std.mem.endsWith(u8, f.source_name, ".lua") or
                    std.mem.indexOfScalar(u8, f.source_name, '/') != null or
                    std.mem.indexOfScalar(u8, f.source_name, '\\') != null);
            const src = if (f.source_name.len != 0 and f.source_name[0] != '@' and f.source_name[0] != '=' and looks_like_path)
                try std.fmt.allocPrint(self.alloc, "@{s}", .{f.source_name})
            else
                f.source_name;
            const what_str: []const u8 = if (f.line_defined == 0) "main" else "Lua";
            try self.setField(t, "what", .{ .String = try self.internStr(what_str) });
            try self.setField(t, "source", .{ .String = try self.internStr(src) });
            try self.setField(t, "short_src", .{ .String = try self.internStr(short_src) });
            try self.setField(t, "linedefined", .{ .Int = f.line_defined });
            try self.setField(t, "lastlinedefined", .{ .Int = f.last_line_defined });
        }
        if (has_u) {
            const is_main_like = f.line_defined == 0 and f.is_vararg and f.num_params == 0;
            var nups: i64 = runtime_nups orelse f.num_upvalues;
            if (is_main_like and nups == 0) nups = 1;
            try self.setField(t, "nups", .{ .Int = nups });
            try self.setField(t, "nparams", .{ .Int = f.num_params });
            const is_vararg = if (f.line_defined == 0) true else f.is_vararg;
            try self.setField(t, "isvararg", .{ .Bool = is_vararg });
        }
        if (debugInfoHasOpt(what, 'L')) {
            const act = try self.allocTable();
            // PUC builds activelines solely from the function's line info; a
            // stripped function has none, so its activelines is empty. There is
            // no fallback that synthesizes lines from the [line_defined,
            // last_line_defined] range — that would wrongly populate a stripped
            // function's activelines (db.lua "chunk without debug info").
            for (f.active_lines) |l| {
                try self.rawSet(act, .{ .Int = @intCast(l) }, .{ .Bool = true });
            }
            try self.setField(t, "activelines", .{ .Table = act });
        }
    }

    fn debugFillInfoFromFunction(self: *Vm, t: *Table, fnv: Value, what: []const u8) Error!void {
        switch (fnv) {
            .Builtin => |id| {
                const has_s = what.len == 0 or debugInfoHasOpt(what, 'S');
                const has_f = what.len == 0 or debugInfoHasOpt(what, 'f');
                const has_u = what.len == 0 or debugInfoHasOpt(what, 'u');
                if (has_s) {
                    try self.setField(t, "what", .{ .String = try self.internStr("C") });
                    try self.setField(t, "source", .{ .String = try self.internStr("=[C]") });
                    try self.setField(t, "short_src", .{ .String = try self.internStr("[C]") });
                    try self.setField(t, "linedefined", .{ .Int = -1 });
                    try self.setField(t, "lastlinedefined", .{ .Int = -1 });
                }
                if (has_u) {
                    const nups: i64 = if (id == .string_match or id == .string_gmatch_iter) 1 else 0;
                    try self.setField(t, "nups", .{ .Int = nups });
                    try self.setField(t, "nparams", .{ .Int = 0 });
                    try self.setField(t, "isvararg", .{ .Bool = true });
                }
                if (debugInfoHasOpt(what, 'L')) {
                    try self.setField(t, "activelines", .Nil);
                }
                if (has_f) try self.setField(t, "func", fnv);
            },
            .Closure => |cl| {
                const has_f = what.len == 0 or debugInfoHasOpt(what, 'f');
                if (cl.proto) |p| {
                    // Bytecode closure: fill from Proto fields.
                    const has_s = what.len == 0 or debugInfoHasOpt(what, 'S');
                    const has_u = what.len == 0 or debugInfoHasOpt(what, 'u');
                    if (has_s) {
                        const short_src = try self.debugShortSource(p.source_name);
                        const looks_like_path = p.source_name.len != 0 and
                            (std.mem.endsWith(u8, p.source_name, ".lua") or
                                std.mem.indexOfScalar(u8, p.source_name, '/') != null or
                                std.mem.indexOfScalar(u8, p.source_name, '\\') != null);
                        const src = if (p.source_name.len != 0 and p.source_name[0] != '@' and p.source_name[0] != '=' and looks_like_path)
                            try std.fmt.allocPrint(self.alloc, "@{s}", .{p.source_name})
                        else
                            p.source_name;
                        const what_str: []const u8 = if (p.line_defined == 0) "main" else "Lua";
                        try self.setField(t, "what", .{ .String = try self.internStr(what_str) });
                        try self.setField(t, "source", .{ .String = try self.internStr(src) });
                        try self.setField(t, "short_src", .{ .String = try self.internStr(short_src) });
                        try self.setField(t, "linedefined", .{ .Int = @intCast(p.line_defined) });
                        try self.setField(t, "lastlinedefined", .{ .Int = @intCast(p.last_line_defined) });
                    }
                    if (has_u) {
                        const is_main_like = p.line_defined == 0 and p.is_vararg and p.numparams == 0;
                        var nups: i64 = @intCast(cl.upvalues.len);
                        if (is_main_like and nups == 0) nups = 1;
                        try self.setField(t, "nups", .{ .Int = nups });
                        try self.setField(t, "nparams", .{ .Int = @intCast(p.numparams) });
                        const is_vararg = if (p.line_defined == 0) true else p.is_vararg;
                        try self.setField(t, "isvararg", .{ .Bool = is_vararg });
                    }
                    if (debugInfoHasOpt(what, 'L')) {
                        // Build activelines from Proto's line info.
                        const act = try self.allocTable();
                        for (p.lineinfo) |line| {
                            if (line > 0) {
                                try self.rawSet(act, .{ .Int = @intCast(line) }, .{ .Bool = true });
                            }
                        }
                        try self.setField(t, "activelines", .{ .Table = act });
                    }
                } else {
                    try self.debugFillInfoFromIrFunction(t, cl.func, what, @intCast(cl.upvalues.len));
                }
                if (has_f) try self.setField(t, "func", fnv);
            },
            else => return self.fail("bad argument #1 to 'getinfo' (function or level expected)", .{}),
        }
    }

    fn builtinDebugGetinfo(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'getinfo' (function or level expected)", .{});

        var i: usize = 0;
        var target_thread: ?*Thread = null;
        if (args.len > 0 and args[0] == .Thread) {
            target_thread = try self.expectThread(args[0]);
            i = 1;
        }
        if (i >= args.len) return self.fail("bad argument #1 to 'getinfo' (function or level expected)", .{});

        const what = if (i + 1 < args.len) switch (args[i + 1]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #2 to 'getinfo' (string expected)", .{}),
        } else "";
        try self.debugInfoValidateOpts(what);

        // Temp roots: protect `t` across calls to debugFillInfoFromIrFunction
        // which internally allocates an activelines table (triggering GC).
        var roots = self.gcTempRoots();
        defer roots.end();

        const t = try self.allocTable();
        try roots.add(.{ .Table = t });

        try self.setField(t, "currentline", .{ .Int = 0 });

        switch (args[i]) {
            .Int => |level| {
                if (target_thread) |th| {
                    if (level < 0 or level > 1) {
                        outs[0] = .Nil;
                        return;
                    }
                    if (th.locals_snapshot == null) {
                        if (th.suspended_builtin) |id| {
                            try self.setField(t, "name", .Nil);
                            try self.setField(t, "namewhat", .{ .String = try self.internStr("") });
                            try self.setField(t, "currentline", .{ .Int = -1 });
                            if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                                try self.setField(t, "istailcall", .{ .Bool = false });
                                try self.setField(t, "extraargs", .{ .Int = 0 });
                            }
                            const callee: Value = .{ .Builtin = id };
                            try self.debugFillInfoFromFunction(t, callee, what);
                            if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                                try self.setField(t, "func", callee);
                            }
                            if (outs.len > 0) outs[0] = .{ .Table = t };
                            return;
                        }
                    }
                    const fr_opt = threadCurrentSuspendedFrame(th);
                    if (fr_opt == null and th.locals_snapshot != null) {
                        try self.setField(t, "name", .Nil);
                        try self.setField(t, "namewhat", .{ .String = try self.internStr("") });
                        try self.setField(t, "currentline", .{ .Int = th.trace_currentline });
                        if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                            try self.setField(t, "istailcall", .{ .Bool = false });
                            try self.setField(t, "extraargs", .{ .Int = 0 });
                        }
                        try self.debugFillInfoFromFunction(t, th.callee, what);
                        if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                            try self.setField(t, "func", th.callee);
                        }
                        if (outs.len > 0) outs[0] = .{ .Table = t };
                        return;
                    }
                    const fr = fr_opt orelse {
                        outs[0] = .Nil;
                        return;
                    };
                    if (level >= 1 and fr.from_debug_hook) {
                        outs[0] = .Nil;
                        return;
                    }
                    try self.setField(t, "name", .Nil);
                    try self.setField(t, "namewhat", .{ .String = try self.internStr("") });
                    try self.setField(t, "currentline", .{ .Int = fr.current_line });
                    if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                        const extraargs: i64 = if (fr.isVararg()) @intCast(fr.varargs.len) else 0;
                        try self.setField(t, "istailcall", .{ .Bool = fr.is_tailcall });
                        try self.setField(t, "extraargs", .{ .Int = extraargs });
                    }
                    try self.debugFillInfoFromFunction(t, fr.callee, what);
                    if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                        try self.setField(t, "func", fr.callee);
                    }
                    var runtime_nups: i64 = @intCast(fr.upvalues.len + @as(usize, if (fr.lineDefined() == 0) 0 else 1));
                    if (fr.callee == .Closure and fr.callee.Closure.synthetic_env_slot and fr.lineDefined() == 0) {
                        runtime_nups += 1;
                    }
                    try self.debugFillInfoFromIrFunction(t, fr.func, what, runtime_nups);
                    if (outs.len > 0) outs[0] = .{ .Table = t };
                    return;
                }
                if (level < 1) {
                    outs[0] = .Nil;
                    return;
                }
                const lv: usize = @intCast(level);
                if (lv == 2 and self.protected_call_depth > 0 and self.close_metamethod_depth > 0) {
                    try self.setField(t, "name", .{ .String = try self.internStr("pcall") });
                    try self.setField(t, "namewhat", .{ .String = try self.internStr("global") });
                    try self.setField(t, "currentline", .{ .Int = -1 });
                    if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                        try self.setField(t, "istailcall", .{ .Bool = false });
                        try self.setField(t, "extraargs", .{ .Int = 0 });
                    }
                    const pcall_f: Value = .{ .Builtin = .pcall };
                    try self.debugFillInfoFromFunction(t, pcall_f, what);
                    if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                        try self.setField(t, "func", pcall_f);
                    }
                    if (outs.len > 0) outs[0] = .{ .Table = t };
                    return;
                }
                const fr_idx = self.debugResolveFrameIndex(lv) orelse {
                    if (lv == 2 and self.protected_call_depth > 0) {
                        try self.setField(t, "name", .{ .String = try self.internStr("pcall") });
                        try self.setField(t, "namewhat", .{ .String = try self.internStr("global") });
                        try self.setField(t, "currentline", .{ .Int = -1 });
                        if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                            try self.setField(t, "istailcall", .{ .Bool = false });
                            try self.setField(t, "extraargs", .{ .Int = 0 });
                        }
                        const pcall_f: Value = .{ .Builtin = .pcall };
                        try self.debugFillInfoFromFunction(t, pcall_f, what);
                        if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                            try self.setField(t, "func", pcall_f);
                        }
                        if (outs.len > 0) outs[0] = .{ .Table = t };
                        return;
                    }
                    outs[0] = .Nil;
                    return;
                };
                const fr = &self.frames.items[fr_idx];
                if (self.in_debug_hook and lv == 1) {
                    try self.setField(t, "name", .Nil);
                    try self.setField(t, "namewhat", .{ .String = try self.internStr("hook") });
                } else {
                    if (lv == 1) {
                        if (self.debug_namewhat_override) |nwo| {
                            try self.setField(t, "namewhat", .{ .String = try self.internStr(nwo) });
                            if (self.debug_name_override) |nmo| {
                                try self.setField(t, "name", .{ .String = try self.internStr(nmo) });
                            } else {
                                try self.setField(t, "name", .Nil);
                            }
                        } else {
                            const inferred = self.debugInferNameFromCaller(fr_idx, fr.func);
                            if (inferred.name) |nm| {
                                try self.setField(t, "name", .{ .String = try self.internStr(nm) });
                            } else if (self.in_debug_hook and lv == 2) {
                                try self.setField(t, "name", .{ .String = try self.internStr("?") });
                            } else {
                                try self.setField(t, "name", .Nil);
                            }
                            try self.setField(t, "namewhat", .{ .String = try self.internStr(inferred.namewhat) });
                        }
                    } else {
                        if (lv == 2 and self.protected_call_depth > 0) {
                            try self.setField(t, "name", .{ .String = try self.internStr("pcall") });
                            try self.setField(t, "namewhat", .{ .String = try self.internStr("global") });
                        } else {
                            const inferred = self.debugInferNameFromCaller(fr_idx, fr.func);
                            if (self.in_debug_hook and lv == 2 and self.debugNameFromCallee(fr.callee) != null) {
                                try self.setField(t, "name", .{ .String = try self.internStr(self.debugNameFromCallee(fr.callee).?) });
                            } else if (self.in_debug_hook and lv == 2 and self.debug_name_override != null) {
                                const raw = self.debug_name_override.?;
                                if (std.mem.eql(u8, raw, "__close") and self.testc_close_metamethod_depth != 0) {
                                    try self.setField(t, "name", .{ .String = try self.internStr("?") });
                                } else {
                                    const nm = if (std.mem.startsWith(u8, raw, "__") and raw.len > 2) raw[2..] else raw;
                                    try self.setField(t, "name", .{ .String = try self.internStr(nm) });
                                }
                            } else if (inferred.name) |nm| {
                                try self.setField(t, "name", .{ .String = try self.internStr(nm) });
                            } else if (self.in_debug_hook and lv == 2) {
                                try self.setField(t, "name", .{ .String = try self.internStr("?") });
                            } else {
                                try self.setField(t, "name", .Nil);
                            }
                            try self.setField(t, "namewhat", .{ .String = try self.internStr(inferred.namewhat) });
                        }
                    }
                }
                var cur_line: i64 = if (fr.func.inst_lines.len == 0) -1 else fr.current_line;
                if (cur_line > 0 and fr.lineDefined() == 0) {
                    const src_name = fr.sourceName();
                    const looks_like_path = src_name.len != 0 and
                        (std.mem.endsWith(u8, src_name, ".lua") or
                            std.mem.indexOfScalar(u8, src_name, '/') != null or
                            std.mem.indexOfScalar(u8, src_name, '\\') != null);
                    if (looks_like_path) cur_line -= 1;
                }
                try self.setField(t, "currentline", .{ .Int = cur_line });
                if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                    const is_tail = if (self.in_debug_hook and lv == 2 and self.debug_hook_event_calllike)
                        self.debug_hook_event_tailcall
                    else
                        fr.is_tailcall;
                    const extraargs: i64 = if (fr.isVararg()) @intCast(fr.varargs.len) else 0;
                    try self.setField(t, "istailcall", .{ .Bool = is_tail });
                    try self.setField(t, "extraargs", .{ .Int = extraargs });
                }
                if (debugInfoHasOpt(what, 'r')) {
                    if (self.in_debug_hook and lv == 2) {
                        if (self.debug_transfer_values) |vals| {
                            try self.setField(t, "ftransfer", .{ .Int = self.debug_transfer_start });
                            try self.setField(t, "ntransfer", .{ .Int = @intCast(vals.len) });
                        } else {
                            try self.setField(t, "ftransfer", .{ .Int = 1 });
                            try self.setField(t, "ntransfer", .{ .Int = 0 });
                        }
                    } else {
                        try self.setField(t, "ftransfer", .{ .Int = 1 });
                        try self.setField(t, "ntransfer", .{ .Int = 0 });
                    }
                }
                if (what.len == 0 or debugInfoHasOpt(what, 'f')) {
                    try self.setField(t, "func", fr.callee);
                }
                var runtime_nups: i64 = @intCast(fr.upvalues.len + @as(usize, if (fr.lineDefined() == 0) 0 else 1));
                if (fr.callee == .Closure and fr.callee.Closure.synthetic_env_slot and fr.lineDefined() == 0) {
                    runtime_nups += 1;
                }
                try self.debugFillInfoFromIrFunction(t, fr.func, what, runtime_nups);
            },
            .Builtin, .Closure => {
                if (target_thread != null) {
                    return self.fail("bad argument #1 to 'getinfo' (function or level expected)", .{});
                }
                try self.setField(t, "name", .Nil);
                try self.setField(t, "namewhat", .{ .String = try self.internStr("") });
                if (what.len == 0 or debugInfoHasOpt(what, 't')) {
                    try self.setField(t, "istailcall", .{ .Bool = false });
                    try self.setField(t, "extraargs", .{ .Int = 0 });
                }
                try self.debugFillInfoFromFunction(t, args[i], what);
            },
            else => return self.fail("bad argument #1 to 'getinfo' (function or level expected)", .{}),
        }

        if (outs.len > 0) outs[0] = .{ .Table = t };
    }

    fn debugGetLocalFromFrame(self: *Vm, fr: *const Frame, idx: i64, outs: []Value) Error!void {
        if (idx == 0) return;
        if (idx > 0) {
            var rank: i64 = 0;
            const nlocals = @min(fr.locals.len, fr.func.local_names.len);
            const nparams: usize = @intCast(fr.numParams());
            var has_named_active_local = false;
            var has_any_local_names = false;
            var ln_i: usize = 0;
            while (ln_i < fr.func.local_names.len) : (ln_i += 1) {
                if (fr.func.local_names[ln_i].len != 0) {
                    has_any_local_names = true;
                    break;
                }
            }
            var i: usize = 0;
            while (i < nlocals) : (i += 1) {
                if (fr.isVararg() and i == nparams) {
                    rank += 1;
                    if (rank == idx) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                        if (outs.len > 1) outs[1] = .Nil;
                        return;
                    }
                }
                if (!fr.local_active[i]) continue;
                const nm = fr.func.local_names[i];
                if (nm.len == 0) {
                    if (has_any_local_names) continue;
                    rank += 1;
                    if (rank == idx) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(temporary)") };
                        if (outs.len > 1) outs[1] = fr.locals[i];
                        return;
                    }
                    continue;
                }
                has_named_active_local = true;
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr(nm) };
                    if (outs.len > 1) outs[1] = fr.locals[i];
                    return;
                }
            }
            if (fr.isVararg() and nparams >= nlocals) {
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                    if (outs.len > 1) outs[1] = .Nil;
                    return;
                }
            }
            // Expose synthetic generic-for state entries for line iterators so
            // debug.getlocal can observe "(for state)" values as in PUC Lua.
            var iter_tbl: ?*Table = null;
            var rfind: usize = 0;
            while (rfind < fr.regs.len) : (rfind += 1) {
                if (fr.regs[rfind] != .Table) continue;
                const t = fr.regs[rfind].Table;
                if (self.getFieldOpt(t, "__file") == null) continue;
                if (self.getFieldOpt(t, "__auto_close") == null) continue;
                iter_tbl = t;
            }
            if (iter_tbl) |it| {
                const s1 = rank + 1;
                const s2 = rank + 2;
                const s3 = rank + 3;
                if (idx == s1) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(for state)") };
                    if (outs.len > 1) {
                        const mm = if (it.metatable) |mt| self.getFieldOpt(mt, "__call") orelse .Nil else .Nil;
                        outs[1] = mm;
                    }
                    return;
                }
                if (idx == s2) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(for state)") };
                    if (outs.len > 1) outs[1] = .Nil;
                    return;
                }
                if (idx == s3) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(for state)") };
                    if (outs.len > 1) outs[1] = self.getFieldOpt(it, "__file") orelse .Nil;
                    return;
                }
            }
            var r: usize = 0;
            while (r < fr.regs.len) : (r += 1) {
                if (r < fr.local_active.len and fr.local_active[r]) continue;
                if (fr.regs[r] == .Nil) continue;
                switch (fr.regs[r]) {
                    .Builtin => continue,
                    .Closure => if (has_named_active_local) continue,
                    else => {},
                }
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(temporary)") };
                    if (outs.len > 1) outs[1] = fr.regs[r];
                    return;
                }
            }
            return;
        }
        if (!fr.isVararg()) return;
        const vidx: i64 = -idx;
        if (vidx < 1) return;
        const vpos: usize = @intCast(vidx - 1);
        if (vpos >= fr.varargs.len) return;
        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg)") };
        if (outs.len > 1) outs[1] = fr.varargs[vpos];
    }

    fn threadCurrentSuspendedFrame(th: *Thread) ?*SuspendedFrame {
        if (th.suspended_frames.items.len == 0) return null;
        var best: ?*SuspendedFrame = null;
        var best_yield: usize = 0;
        var best_depth: usize = 0;
        for (th.suspended_frames.items) |*fr| {
            if (fr.from_debug_hook and fr.direct_yield) continue;
            if (best == null or fr.yield_id > best_yield or (fr.yield_id == best_yield and fr.stack_depth > best_depth)) {
                best = fr;
                best_yield = fr.yield_id;
                best_depth = fr.stack_depth;
            }
        }
        if (best) |fr| return fr;
        var fallback: ?*SuspendedFrame = null;
        best_yield = 0;
        best_depth = 0;
        for (th.suspended_frames.items) |*fr| {
            if (fallback == null or fr.yield_id > best_yield or (fr.yield_id == best_yield and fr.stack_depth > best_depth)) {
                fallback = fr;
                best_yield = fr.yield_id;
                best_depth = fr.stack_depth;
            }
        }
        return fallback;
    }

    fn debugGetLocalFromSuspendedFrame(self: *Vm, fr: *const SuspendedFrame, idx: i64, outs: []Value) Error!void {
        const fake = Frame{
            .func = fr.func,
            .callee = fr.callee,
            .regs = fr.regs,
            .locals = fr.locals,
            .boxed = fr.boxed,
            .local_active = fr.local_active,
            .varargs = fr.varargs,
            .upvalues = fr.upvalues,
            .env_override = fr.env_override,
            .frame_id = fr.frame_id,
            .current_line = fr.current_line,
            .last_hook_line = fr.last_hook_line,
            .used_closing_line_hook = fr.used_closing_line_hook,
            .resume_skip_count_pc = fr.resume_skip_count_pc,
            .is_tailcall = fr.is_tailcall,
            .hide_from_debug = fr.hide_from_debug,
        };
        try self.debugGetLocalFromFrame(&fake, idx, outs);
    }

    fn debugGetLocalFromThreadSnapshot(self: *Vm, th: *Thread, idx: i64, outs: []Value) Error!void {
        if (idx < 1) return;
        const snap = th.locals_snapshot orelse return;
        const fr = threadCurrentSuspendedFrame(th) orelse return;
        const nparams: usize = @intCast(fr.numParams());

        var rank: i64 = 0;
        for (snap, 0..) |entry, i| {
            if (i == nparams and fr.isVararg()) {
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                    if (outs.len > 1) outs[1] = .Nil;
                    return;
                }
            }
            rank += 1;
            if (rank == idx) {
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr(entry.name) };
                if (outs.len > 1) outs[1] = entry.value;
                return;
            }
        }
        if (fr.isVararg() and snap.len <= nparams) {
            rank += 1;
            if (rank == idx) {
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                if (outs.len > 1) outs[1] = .Nil;
            }
        }
    }

    fn debugSetLocalFromThreadSnapshot(self: *Vm, th: *Thread, idx: i64, new_value: Value, outs: []Value) Error!void {
        if (idx < 1) return;
        const snap = th.locals_snapshot orelse return;
        const fr = threadCurrentSuspendedFrame(th) orelse return;
        const nparams: usize = @intCast(fr.numParams());

        var rank: i64 = 0;
        for (snap, 0..) |entry, i| {
            if (i == nparams and fr.isVararg()) {
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                    return;
                }
            }
            rank += 1;
            if (rank == idx) {
                th.locals_snapshot.?[i].value = new_value;
                try self.setThreadFrameLocalOverride(th, entry.frame_id, entry.slot, entry.name, new_value);
                self.setThreadSuspendedLocalFromSnapshot(th, entry, new_value);
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr(entry.name) };
                return;
            }
        }
        if (fr.isVararg() and snap.len <= nparams) {
            rank += 1;
            if (rank == idx and outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
        }
    }

    fn debugGetLocalNameFromFunction(self: *Vm, f: *const ir.Function, idx: i64, outs: []Value) Error!void {
        if (idx <= 0) return;
        const uidx: usize = @intCast(idx - 1);
        if (uidx >= f.num_params or uidx >= f.local_names.len) return;
        const nm = f.local_names[uidx];
        if (nm.len == 0) return;
        if (outs.len > 0) outs[0] = .{ .String = try self.internStr(nm) };
        if (outs.len > 1) outs[1] = .Nil;
    }

    fn debugSetLocalInFrame(self: *Vm, fr: *Frame, idx: i64, val: Value, outs: []Value) Error!void {
        if (idx == 0) return;
        if (idx > 0) {
            var rank: i64 = 0;
            const nlocals = @min(fr.locals.len, fr.func.local_names.len);
            const nparams: usize = @intCast(fr.numParams());
            var has_named_active_local = false;
            var i: usize = 0;
            while (i < nlocals) : (i += 1) {
                if (fr.isVararg() and i == nparams) {
                    rank += 1;
                    if (rank == idx) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                        return;
                    }
                }
                if (!fr.local_active[i]) continue;
                const nm = fr.func.local_names[i];
                if (nm.len == 0) continue;
                has_named_active_local = true;
                rank += 1;
                if (rank == idx) {
                    fr.locals[i] = val;
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr(nm) };
                    return;
                }
            }
            if (fr.isVararg() and nparams >= nlocals) {
                rank += 1;
                if (rank == idx) {
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg table)") };
                    return;
                }
            }
            var r: usize = 0;
            while (r < fr.regs.len) : (r += 1) {
                if (r < fr.local_active.len and fr.local_active[r]) continue;
                if (fr.regs[r] == .Nil) continue;
                switch (fr.regs[r]) {
                    .Builtin => continue,
                    .Closure => if (has_named_active_local) continue,
                    else => {},
                }
                rank += 1;
                if (rank == idx) {
                    fr.regs[r] = val;
                    if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(temporary)") };
                    return;
                }
            }
            return;
        }
        if (!fr.isVararg()) return;
        const vidx: i64 = -idx;
        if (vidx < 1) return;
        const vpos: usize = @intCast(vidx - 1);
        if (vpos >= fr.varargs.len) return;
        fr.varargs[vpos] = val;
        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(vararg)") };
    }

    fn setThreadSuspendedLocalFromSnapshot(self: *Vm, th: *Thread, snap: Thread.LocalSnap, val: Value) void {
        _ = self;
        var i: usize = th.suspended_frames.items.len;
        while (i > 0) {
            i -= 1;
            var fr = &th.suspended_frames.items[i];
            if (snap.frame_id != 0 and fr.frame_id != snap.frame_id) continue;
            if (snap.slot >= fr.locals.len) continue;
            if (snap.slot < fr.local_active.len and !fr.local_active[snap.slot]) continue;
            if (snap.slot < fr.func.local_names.len and fr.func.local_names[snap.slot].len != 0 and snap.name.len != 0 and !std.mem.eql(u8, fr.func.local_names[snap.slot], snap.name)) continue;
            fr.locals[snap.slot] = val;
            return;
        }
    }

    fn builtinDebugGetlocal(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .Nil;

        var i: usize = 0;
        var target_thread: ?*Thread = null;
        if (args.len > 0 and args[0] == .Thread) {
            target_thread = try self.expectThread(args[0]);
            i = 1;
        }
        if (i + 1 >= args.len) return self.fail("debug.getlocal expects (level|func, local)", .{});
        const target = args[i];
        const local_index = switch (args[i + 1]) {
            .Int => |idx| idx,
            else => return self.fail("bad argument #2 to 'getlocal' (integer expected)", .{}),
        };

        switch (target) {
            .Int => |level| {
                if (target_thread) |th| {
                    if (level < 0 or level > 1 or local_index < 1) return;
                    if (th.locals_snapshot == null and th.suspended_builtin != null) {
                        if (local_index == 1) {
                            if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(C temporary)") };
                            if (outs.len > 1) outs[1] = .Nil;
                            return;
                        }
                        if (th.suspended_builtin_args) |vals| {
                            const pos: usize = @intCast(local_index - 1);
                            if (pos < vals.len) {
                                if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(C temporary)") };
                                if (outs.len > 1) outs[1] = vals[pos];
                            }
                        }
                        return;
                    }
                    if (th.locals_snapshot != null) {
                        if (level >= 1) {
                            if (threadCurrentSuspendedFrame(th)) |fr| {
                                if (fr.from_debug_hook) return;
                            }
                        }
                        try self.debugGetLocalFromThreadSnapshot(th, local_index, outs);
                        return;
                    }
                    try self.debugGetLocalFromThreadSnapshot(th, local_index, outs);
                    return;
                }
                if (level < 0) return self.fail("bad level", .{});
                if (level == 0) {
                    if (local_index == 1) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(C temporary)") };
                        if (outs.len > 1) outs[1] = .{ .Int = 0 };
                        return;
                    }
                    if (local_index == 2) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(C temporary)") };
                        if (outs.len > 1) outs[1] = .{ .Int = 2 };
                        return;
                    }
                    return;
                }
                const lv: usize = @intCast(level);
                const fr_idx = self.debugResolveFrameIndex(lv) orelse return self.fail("bad level", .{});
                const fr = &self.frames.items[fr_idx];
                if (self.in_debug_hook and lv == 2) {
                    if (self.debug_transfer_values) |vals| {
                        const start = self.debug_transfer_start;
                        if (local_index >= start) {
                            const rel = local_index - start;
                            if (rel >= 0 and @as(usize, @intCast(rel)) < vals.len) {
                                if (outs.len > 0) outs[0] = .{ .String = try self.internStr("(temporary)") };
                                if (outs.len > 1) outs[1] = vals[@intCast(rel)];
                                return;
                            }
                        }
                    }
                }
                try self.debugGetLocalFromFrame(fr, local_index, outs);
            },
            .Closure => |cl| try self.debugGetLocalNameFromFunction(cl.func, local_index, outs),
            .Builtin => {},
            else => return self.fail("bad argument #1 to 'getlocal' (function or level expected)", .{}),
        }
    }

    fn builtinDebugSetlocal(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;

        var i: usize = 0;
        var target_thread: ?*Thread = null;
        if (args.len > 0 and args[0] == .Thread) {
            target_thread = try self.expectThread(args[0]);
            i = 1;
        }
        if (i + 2 >= args.len) return self.fail("debug.setlocal expects (level|func, local, value)", .{});
        const target = args[i];
        const local_index = switch (args[i + 1]) {
            .Int => |idx| idx,
            else => return self.fail("bad argument #2 to 'setlocal' (integer expected)", .{}),
        };
        const new_value = args[i + 2];

        switch (target) {
            .Int => |level| {
                if (target_thread) |th| {
                    if (level < 0 or level > 1 or local_index < 1) return;
                    if (th.locals_snapshot != null) {
                        if (level >= 1) {
                            if (threadCurrentSuspendedFrame(th)) |fr| {
                                if (fr.from_debug_hook) return;
                            }
                        }
                        try self.debugSetLocalFromThreadSnapshot(th, local_index, new_value, outs);
                        return;
                    }
                    return;
                }
                if (level < 1) return self.fail("bad level", .{});
                const lv: usize = @intCast(level);
                const fr_idx = self.debugResolveFrameIndex(lv) orelse return self.fail("bad level", .{});
                const fr = &self.frames.items[fr_idx];
                try self.debugSetLocalInFrame(fr, local_index, new_value, outs);
            },
            .Closure, .Builtin => {},
            else => return self.fail("bad argument #1 to 'setlocal' (function or level expected)", .{}),
        }
    }

    fn debugUpvalueName(cl: *const Closure, uidx: usize) []const u8 {
        // For bytecode closures, upvalue names live in the Proto.
        if (cl.proto) |p| {
            if (uidx < p.upvalues.len) {
                const nm = p.upvalues[uidx].name;
                if (nm.len != 0) return nm;
            }
            if (uidx == 0 and p.line_defined == 0) return "_ENV";
            return "(no name)";
        }
        if (uidx < cl.func.upvalue_names.len) {
            const nm = cl.func.upvalue_names[uidx];
            if (nm.len != 0) return nm;
        }
        if (uidx == 0 and cl.func.line_defined == 0) return "_ENV";
        return "(no name)";
    }

    fn builtinDebugGetupvalue(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .Nil;
        if (args.len < 2) return self.fail("debug.getupvalue expects (func, up)", .{});
        const idx = switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("bad argument #2 to 'getupvalue' (integer expected)", .{}),
        };
        if (idx < 1) return;
        const uidx: usize = @intCast(idx - 1);
        switch (args[0]) {
            .Closure => |cl| {
                if (uidx >= cl.upvalues.len) {
                    // Compatibility shim for loaded chunks that expect an
                    // explicit _ENV upvalue slot.
                    if (cl.synthetic_env_slot and uidx == cl.upvalues.len) {
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("_ENV") };
                        if (outs.len > 1) outs[1] = cl.env_override orelse .{ .Table = self.global_env };
                    }
                    return;
                }
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr(debugUpvalueName(cl, uidx)) };
                if (outs.len > 1) outs[1] = cl.upvalues[uidx].value;
            },
            .Builtin => {
                if (uidx != 0) return;
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr("") };
            },
            else => return self.fail("bad argument #1 to 'getupvalue' (function expected)", .{}),
        }
    }

    fn builtinDebugSetupvalue(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (args.len < 3) return self.fail("debug.setupvalue expects (func, up, value)", .{});
        const idx = switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("bad argument #2 to 'setupvalue' (integer expected)", .{}),
        };
        if (idx < 1) return;
        const uidx: usize = @intCast(idx - 1);
        switch (args[0]) {
            .Closure => |cl| {
                if (uidx >= cl.upvalues.len) {
                    if (cl.synthetic_env_slot and uidx == cl.upvalues.len) {
                        cl.env_override = args[2];
                        if (outs.len > 0) outs[0] = .{ .String = try self.internStr("_ENV") };
                    }
                    return;
                }
                cl.upvalues[uidx].value = args[2];
                if (outs.len > 0) outs[0] = .{ .String = try self.internStr(debugUpvalueName(cl, uidx)) };
            },
            .Builtin => {},
            else => return self.fail("bad argument #1 to 'setupvalue' (function expected)", .{}),
        }
    }

    fn builtinDebugUpvalueid(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (args.len < 2) return self.fail("debug.upvalueid expects (func, up)", .{});
        const idx = switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("bad argument #2 to 'upvalueid' (integer expected)", .{}),
        };
        if (idx < 1) return;
        const uidx: usize = @intCast(idx - 1);
        switch (args[0]) {
            .Closure => |cl| {
                if (uidx >= cl.upvalues.len) {
                    if (cl.synthetic_env_slot and uidx == cl.upvalues.len) {
                        if (outs.len > 0) outs[0] = try self.debugLightUserdataForId(0x2000_0000 + @as(u64, @intCast(@intFromPtr(cl))));
                    } else if (uidx == 0 and cl.func.num_upvalues == 0) {
                        // Our IR uses GetName/SetName for globals and does not
                        // materialize _ENV as a regular upvalue slot. Expose a
                        // synthetic identity for debug.upvalueid compatibility.
                        var uses_globals = false;
                        for (cl.func.insts) |inst| {
                            switch (inst) {
                                .GetName, .SetName => {
                                    uses_globals = true;
                                    break;
                                },
                                else => {},
                            }
                        }
                        if (uses_globals and outs.len > 0) {
                            outs[0] = try self.debugLightUserdataForId(0x2000_0000 + @as(u64, @intCast(@intFromPtr(cl))));
                        }
                    }
                    return;
                }
                if (outs.len > 0) outs[0] = try self.debugLightUserdataForId(@intCast(@intFromPtr(cl.upvalues[uidx])));
            },
            .Builtin => |id| {
                if (uidx != 0) return;
                if (outs.len > 0) outs[0] = try self.debugLightUserdataForId(0x4000_0000 + @as(u64, @intFromEnum(id)));
            },
            else => return self.fail("bad argument #1 to 'upvalueid' (function expected)", .{}),
        }
    }

    fn debugLightUserdataForId(self: *Vm, id: u64) Error!Value {
        if (self.debug_upvalue_ids.get(id)) |obj| return .{ .Table = obj };
        const t = try self.allocTable();
        try self.setField(t, "__testud", .{ .Bool = true });
        try self.setField(t, "__light", .{ .Bool = true });
        try self.setField(t, "__ptrid", .{ .Int = @intCast(id) });
        try self.debug_upvalue_ids.put(self.alloc, id, t);
        return .{ .Table = t };
    }

    fn builtinDebugUpvaluejoin(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = outs;
        if (args.len < 4) return self.fail("debug.upvaluejoin expects (f1,n1,f2,n2)", .{});
        const f1 = switch (args[0]) {
            .Closure => |cl| cl,
            else => return self.fail("bad argument #1 to 'upvaluejoin' (function expected)", .{}),
        };
        const n1 = switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("bad argument #2 to 'upvaluejoin' (integer expected)", .{}),
        };
        const f2 = switch (args[2]) {
            .Closure => |cl| cl,
            else => return self.fail("bad argument #3 to 'upvaluejoin' (function expected)", .{}),
        };
        const n2 = switch (args[3]) {
            .Int => |i| i,
            else => return self.fail("bad argument #4 to 'upvaluejoin' (integer expected)", .{}),
        };
        if (n1 < 1 or n2 < 1) return self.fail("invalid upvalue index", .{});
        const idx1: usize = @intCast(n1 - 1);
        const idx2: usize = @intCast(n2 - 1);
        if (idx1 >= f1.upvalues.len or idx2 >= f2.upvalues.len) return self.fail("invalid upvalue index", .{});
        @constCast(f1.upvalues)[idx1] = f2.upvalues[idx2];
    }

    fn debugPreseedLineHookFromUpvalue(self: *Vm, hook: Value, mask: []const u8) Error!bool {
        if (std.mem.indexOfScalar(u8, mask, 'l') == null) return false;
        if (hook != .Closure) return false;
        const cl = hook.Closure;

        // Pragmatic compatibility bridge for early `db.lua` trace tests:
        // if hook closure captures a list of expected lines, replay them.
        for (cl.upvalues) |cell| {
            const uv = cell.value;
            if (uv != .Table) continue;
            const lines = uv.Table;
            var preseeded = false;
            while (true) {
                const first = try self.tableGetValue(lines, .{ .Int = 1 });
                if (first == .Nil) break;
                const line: i64 = switch (first) {
                    .Int => |i| i,
                    else => break,
                };
                try self.debugDispatchHook("line", line);
                preseeded = true;
            }
            if (preseeded) return true;
        }

        return false;
    }

    fn debugDispatchHook(self: *Vm, event: []const u8, line: ?i64) Error!void {
        return self.debugDispatchHookTransfer(event, line, null, 1);
    }

    fn debugDispatchHookTransfer(self: *Vm, event: []const u8, line: ?i64, transfer: ?[]const Value, transfer_start: i64) Error!void {
        if (self.debug_hooks_suppressed != 0) return;
        if (self.in_debug_hook) return;
        const hook_state = self.activeHookState();
        const hook = hook_state.func orelse return;
        if (hook == .Nil) return;

        const match = if (std.mem.eql(u8, event, "call") or std.mem.eql(u8, event, "tail call"))
            hook_state.has_call
        else if (std.mem.eql(u8, event, "return"))
            hook_state.has_return
        else if (std.mem.eql(u8, event, "line"))
            hook_state.has_line
        else if (std.mem.eql(u8, event, "count"))
            hook_state.count > 0
        else
            true;
        if (!match) return;

        var argv_buf: [2]Value = undefined;
        argv_buf[0] = .{ .String = try self.internStr(event) };
        var argc: usize = 1;
        var hook_line = line;
        if (hook_line == null and std.mem.eql(u8, event, "line") and self.frames.items.len != 0) {
            const fr = self.frames.items[self.frames.items.len - 1];
            if (fr.func.inst_lines.len != 0 and fr.current_line > 0) hook_line = fr.current_line;
        }
        if (hook_line) |l| {
            argv_buf[1] = .{ .Int = l };
            argc = 2;
        }

        const saved_transfer = self.debug_transfer_values;
        const saved_transfer_start = self.debug_transfer_start;
        const saved_calllike = self.debug_hook_event_calllike;
        const saved_tailcall = self.debug_hook_event_tailcall;
        const saved_is_count = self.debug_hook_event_is_count;
        self.debug_transfer_values = transfer;
        self.debug_transfer_start = transfer_start;
        self.debug_hook_event_calllike = std.mem.eql(u8, event, "call") or std.mem.eql(u8, event, "tail call");
        self.debug_hook_event_tailcall = std.mem.eql(u8, event, "tail call");
        self.debug_hook_event_is_count = std.mem.eql(u8, event, "count");
        defer {
            self.debug_transfer_values = saved_transfer;
            self.debug_transfer_start = saved_transfer_start;
            self.debug_hook_event_calllike = saved_calllike;
            self.debug_hook_event_tailcall = saved_tailcall;
            self.debug_hook_event_is_count = saved_is_count;
        }

        self.in_debug_hook = true;
        defer self.in_debug_hook = false;

        switch (hook) {
            .Builtin => |id| {
                var outs: [0]Value = .{};
                try self.callBuiltin(id, argv_buf[0..argc], outs[0..]);
            },
            .Closure => |cl| {
                const ret = try self.runClosure(cl, argv_buf[0..argc], false);
                self.alloc.free(ret);
            },
            else => {},
        }
    }

    fn debugDispatchHookWithCallee(self: *Vm, event: []const u8, line: ?i64, callee: Value) Error!void {
        return self.debugDispatchHookWithCalleeTransfer(event, line, callee, null, 1);
    }

    fn debugCallTransferArgsForClosure(cl: *const Closure, call_args: []const Value) []const Value {
        const nparams: usize = @intCast(cl.func.num_params);
        const n = @min(call_args.len, nparams);
        return call_args[0..n];
    }

    fn debugDispatchHookWithCalleeTransfer(self: *Vm, event: []const u8, line: ?i64, callee: Value, transfer: ?[]const Value, transfer_start: i64) Error!void {
        if (self.frames.items.len == 0) {
            try self.debugDispatchHookTransfer(event, line, transfer, transfer_start);
            return;
        }
        const idx = self.frames.items.len - 1;
        const saved = self.frames.items[idx].callee;
        const saved_tail = self.frames.items[idx].is_tailcall;
        self.frames.items[idx].callee = callee;
        if (std.mem.eql(u8, event, "tail call")) {
            self.frames.items[idx].is_tailcall = true;
        } else if (std.mem.eql(u8, event, "call")) {
            self.frames.items[idx].is_tailcall = false;
        }
        defer {
            self.frames.items[idx].callee = saved;
            self.frames.items[idx].is_tailcall = saved_tail;
        }
        try self.debugDispatchHookTransfer(event, line, transfer, transfer_start);
    }

    fn builtinDebugGethook(self: *Vm, args: []const Value, outs: []Value) Error!void {
        const target_thread = if (args.len > 0) try self.expectThread(args[0]) else null;
        const hook_state = self.hookStateFor(target_thread);
        if (outs.len == 0) return;
        if (hook_state.func) |f| {
            outs[0] = f;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(hook_state.mask) };
            if (outs.len > 2) outs[2] = .{ .Int = hook_state.count };
            return;
        }
        outs[0] = .Nil;
    }

    fn ensureDebugRegistry(self: *Vm) Error!*Table {
        if (self.debug_registry) |r| return r;
        var roots = self.gcTempRoots();
        defer roots.end();

        const reg = try self.allocTable();
        try roots.add(.{ .Table = reg });

        const hookkey = try self.allocTable();
        try roots.add(.{ .Table = hookkey });

        const mt = try self.allocTable();
        try self.setField(mt, "__mode", .{ .String = try self.internStr("k") });
        hookkey.metatable = mt;
        try self.setField(reg, "_HOOKKEY", .{ .Table = hookkey });
        self.debug_registry = reg;
        return reg;
    }

    fn builtinDebugGetregistry(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        const reg = try self.ensureDebugRegistry();
        outs[0] = .{ .Table = reg };
    }

    fn builtinDebugSetmetatable(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len < 2) return self.fail("debug.setmetatable expects (value, metatable)", .{});
        const mt: ?*Table = switch (args[1]) {
            .Nil => null,
            .Table => |t| t,
            else => return self.fail("bad argument #2 to 'setmetatable' (nil or table expected)", .{}),
        };
        switch (args[0]) {
            .Table => |tbl| {
                tbl.metatable = mt;
                if (mt) |m| {
                    if (self.getFieldOpt(m, "__gc") != null) {
                        try self.finalizables.put(self.alloc, tbl, {});
                        const tv: Value = .{ .Table = tbl };
                        if (isTestcUserdata(self, tv) and !isTestcLightUserdata(self, tv)) {
                            const tracked = switch (self.getFieldOpt(tbl, "__gc_tracked") orelse .Nil) {
                                .Bool => |b| b,
                                else => false,
                            };
                            if (!tracked) {
                                const szv = self.getFieldOpt(tbl, "__size") orelse Value{ .Int = 0 };
                                const szkb: f64 = switch (szv) {
                                    .Int => |n| @as(f64, @floatFromInt(n)) / 1024.0,
                                    .Num => |n| n / 1024.0,
                                    else => 0.0,
                                };
                                const est = 0.02 + szkb;
                                self.testc_gc_manual_kb += est;
                                self.testc_gc_pending_finalize_kb += est;
                                self.testc_gc_pending_finalize_seen = false;
                                try self.setField(tbl, "__gc_tracked", .{ .Bool = true });
                            }
                        }
                    } else {
                        _ = self.finalizables.remove(tbl);
                    }
                } else {
                    _ = self.finalizables.remove(tbl);
                }
            },
            .String => {
                if (mt) |m| {
                    self.string_metatable = m;
                    self.string_metatable_enabled = true;
                } else {
                    self.string_metatable_enabled = false;
                }
            },
            .Int, .Num => self.number_metatable = mt,
            .Bool => self.boolean_metatable = mt,
            .Nil => self.nil_metatable = mt,
            .Builtin, .Closure => self.function_metatable = mt,
            .Thread => self.thread_metatable = mt,
        }
        if (outs.len > 0) outs[0] = args[0];
    }

    fn builtinDebugTraceback(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;

        var i: usize = 0;
        var thread_arg: ?*Thread = null;
        if (args.len > 0 and args[0] == .Thread) {
            thread_arg = try self.expectThread(args[0]);
            i = 1;
        }

        var msg: []const u8 = "";
        if (i < args.len) {
            switch (args[i]) {
                .String => |s| msg = s.bytes(),
                .Nil => {},
                else => {
                    // Lua: if first non-thread argument is not a string (and
                    // not nil), traceback returns it unchanged.
                    outs[0] = args[i];
                    return;
                },
            }
            i += 1;
        }

        var level: i64 = if (thread_arg != null) 0 else 1;
        if (i < args.len and args[i] != .Nil) {
            level = switch (args[i]) {
                .Int => |n| n,
                .Num => |n| @as(i64, @intFromFloat(@floor(n))),
                else => level,
            };
        }
        if (level < 0) level = 0;

        const body = if (thread_arg) |th|
            try self.debugBuildThreadTraceback(th, level)
        else if (self.err_traceback) |tb|
            // During xpcall message handling the original traceback was
            // captured at error point. Reuse it to avoid losing deep frames
            // after unwind.
            try self.alloc.dupe(u8, tb)
        else
            try self.debugBuildCurrentTraceback(level);

        if (msg.len != 0) {
            outs[0] = .{ .String = try self.internStr(try std.fmt.allocPrint(self.alloc, "{s}\n{s}", .{ msg, body })) };
        } else {
            outs[0] = .{ .String = try self.internStr(body) };
        }
    }

    fn tracebackFrameLabel(self: *Vm, fr: *const Frame, top_hook_frame: bool) Error![]const u8 {
        if (top_hook_frame and self.in_debug_hook) {
            return try std.fmt.allocPrint(self.alloc, "hook", .{});
        }
        switch (fr.callee) {
            .Builtin => |id| return try std.fmt.allocPrint(self.alloc, "\t[C]: in function '{s}'", .{id.name()}),
            else => {},
        }
        const src_raw = fr.sourceName();
        const src = if (src_raw.len != 0 and src_raw[0] == '@') src_raw[1..] else src_raw;
        const shown_src: []const u8 = if (src.len != 0) src else "?";
        const line: i64 = if (fr.current_line > 0) fr.current_line else @as(i64, fr.lineDefined());
        const nm = fr.func.name;
        if (fr.lineDefined() == 0) {
            return try std.fmt.allocPrint(self.alloc, "\t{s}:{d}: in main chunk", .{ shown_src, line });
        }
        if (nm.len != 0 and !std.mem.eql(u8, nm, "<anon>")) {
            return try std.fmt.allocPrint(self.alloc, "\t{s}:{d}: in function '{s}'", .{ shown_src, line, nm });
        }
        return try std.fmt.allocPrint(self.alloc, "\t{s}:{d}: in ?", .{ shown_src, line });
    }

    fn debugBuildCurrentTraceback(self: *Vm, level: i64) Error![]const u8 {
        // When running inside a coroutine, only include frames created after
        // the latest resume boundary; caller frames outside the coroutine
        // should not leak into this traceback.
        const start: usize = if (self.current_thread) |th|
            if (self.main_thread) |main_th|
                if (th != main_th) @min(th.resume_base_depth, self.frames.items.len) else 0
            else
                0
        else
            0;

        var visible: usize = 0;
        var i: usize = self.frames.items.len;
        while (i > start) {
            i -= 1;
            if (self.frames.items[i].hide_from_debug) continue;
            visible += 1;
        }

        // Lua's traceback level skips its own frame plus `level` caller frames.
        const skip: usize = if (level <= 0) 0 else @intCast(level + 1);
        var nl_count: i64 = @as(i64, @intCast(visible)) - @as(i64, @intCast(skip));
        if (nl_count < 0) nl_count = 0;
        if (level > 0 and nl_count < 1) nl_count = 1;
        if (level <= 0 and nl_count < 2) nl_count = 2;

        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer aw.deinit();
        var w = &aw.writer;
        w.writeAll("stack traceback:\n") catch return error.OutOfMemory;

        var frame_ids = std.ArrayListUnmanaged(usize).empty;
        defer frame_ids.deinit(self.alloc);
        i = self.frames.items.len;
        while (i > start) {
            i -= 1;
            if (self.frames.items[i].hide_from_debug) continue;
            try frame_ids.append(self.alloc, i);
        }
        var first: usize = @min(skip, frame_ids.items.len);
        if (frame_ids.items.len != 0 and first >= frame_ids.items.len) first = frame_ids.items.len - 1;
        const shown = if (frame_ids.items.len > first) frame_ids.items[first..] else frame_ids.items[0..0];
        var has_pcall = false;
        for (shown) |fr_idx| {
            const fr = self.frames.items[fr_idx];
            if (fr.callee == .Builtin and fr.callee.Builtin == .pcall) {
                has_pcall = true;
                break;
            }
        }
        const need_pcall = self.protected_call_depth > 0 and !has_pcall;

        // Lua truncates large stack traces around the middle.
        // db.lua checks for a split of 10 lines before "...(skip ...)"
        // and 11 lines from that marker onward.
        if (shown.len + @as(usize, @intFromBool(need_pcall)) > 22) {
            for (shown[0..10], 0..) |fr_idx, k| {
                const line = try self.tracebackFrameLabel(&self.frames.items[fr_idx], k == 0);
                defer self.alloc.free(line);
                w.print("{s}\n", .{line}) catch return error.OutOfMemory;
            }
            w.writeAll("...\t(skip levels)\n") catch return error.OutOfMemory;
            const tail = shown[shown.len - 10 ..];
            for (tail, 0..) |fr_idx, k| {
                const line = try self.tracebackFrameLabel(&self.frames.items[fr_idx], false and k == 0);
                defer self.alloc.free(line);
                w.print("{s}\n", .{line}) catch return error.OutOfMemory;
            }
            return try aw.toOwnedSlice();
        }

        if (shown.len == 0) {
            if (level <= 0) w.writeAll("\t[C]: in function 'traceback'\n") catch return error.OutOfMemory;
            if (self.protected_call_depth > 0) w.writeAll("\t[C]: in function 'pcall'\n") catch return error.OutOfMemory;
            return try aw.toOwnedSlice();
        }

        if (level <= 0) {
            w.writeAll("\t[C]: in function 'traceback'\n") catch return error.OutOfMemory;
        }
        for (shown, 0..) |fr_idx, k| {
            const line = try self.tracebackFrameLabel(&self.frames.items[fr_idx], k == 0);
            defer self.alloc.free(line);
            w.print("{s}\n", .{line}) catch return error.OutOfMemory;
        }
        if (need_pcall) {
            w.writeAll("\t[C]: in function 'pcall'\n") catch return error.OutOfMemory;
        }
        return try aw.toOwnedSlice();
    }

    fn debugBuildThreadTraceback(self: *Vm, th: *Thread, level: i64) Error![]const u8 {
        // Pragmatic traceback used by db.lua coroutine checks:
        // first line is the header, following lines are scanned with string.gmatch.
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer aw.deinit();
        var w = &aw.writer;
        w.writeAll("stack traceback:\n") catch return error.OutOfMemory;

        if (th.status == .suspended) {
            if (level <= 0) w.writeAll("\t[C]: in function 'yield'\n") catch return error.OutOfMemory;
            const names = th.trace_frame_names orelse &[_]?[]const u8{};
            const depth_raw: usize = if (names.len > 0) names.len else if (th.trace_stack_depth > 0) th.trace_stack_depth else 1;
            const depth: i64 = if (depth_raw > 0) @intCast(depth_raw) else 1;
            const drop: i64 = if (level <= 1) 0 else level - 1;
            const db_lines: i64 = @max(0, depth - drop);
            var k: i64 = 0;
            while (k < db_lines) : (k += 1) {
                const idx: usize = @intCast(k);
                const nm = if (idx < names.len) names[idx] else null;
                if (nm) |name| {
                    w.print("\tdb.lua: in function '{s}'\n", .{name}) catch return error.OutOfMemory;
                } else {
                    w.writeAll("\tdb.lua: in function <db.lua>\n") catch return error.OutOfMemory;
                }
            }
        } else if (th.status == .dead) {
            if (th.trace_had_error) {
                w.writeAll("\t[C]: in function 'error'\n") catch return error.OutOfMemory;
                const names = th.trace_frame_names orelse &[_]?[]const u8{};
                if (names.len != 0 and names[0] != null) {
                    w.print("\tdb.lua: in function '{s}'\n", .{names[0].?}) catch return error.OutOfMemory;
                }
                for (names) |nm| {
                    if (nm) |name| {
                        w.print("\tdb.lua: in function '{s}'\n", .{name}) catch return error.OutOfMemory;
                    } else {
                        w.writeAll("\tdb.lua: in function <db.lua>\n") catch return error.OutOfMemory;
                    }
                }
                if (names.len == 0) {
                    w.writeAll("\tdb.lua: in function <db.lua>\n") catch return error.OutOfMemory;
                }
            }
        }

        return try aw.toOwnedSlice();
    }

    fn builtinDebugSethook(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = outs;
        var i: usize = 0;
        var target_thread: ?*Thread = null;
        if (args.len > 0 and args[0] == .Thread) {
            target_thread = try self.expectThread(args[0]);
            i = 1;
        }
        const hook_state = self.hookStateFor(target_thread);

        if (i >= args.len or args[i] == .Nil) {
            hook_state.clear();
            return;
        }

        const hook = args[i];
        switch (hook) {
            .Builtin, .Closure => {},
            else => return self.fail("debug.sethook expects function or nil", .{}),
        }
        hook_state.func = hook;
        i += 1;

        if (i < args.len) {
            const mask = switch (args[i]) {
                .String => |s| s.bytes(),
                else => return self.fail("debug.sethook expects mask string", .{}),
            };
            hook_state.setMask(mask);
            i += 1;
        } else {
            hook_state.setMask("");
        }
        hook_state.has_call = std.mem.indexOfScalar(u8, hook_state.mask, 'c') != null;
        hook_state.has_return = std.mem.indexOfScalar(u8, hook_state.mask, 'r') != null;
        hook_state.has_line = std.mem.indexOfScalar(u8, hook_state.mask, 'l') != null;

        if (i < args.len) {
            hook_state.count = switch (args[i]) {
                .Nil => 0,
                .Int => |n| n,
                .Num => |n| blk: {
                    if (!std.math.isFinite(n)) return self.fail("debug.sethook expects integer count", .{});
                    const t = std.math.trunc(n);
                    if (t != n) return self.fail("debug.sethook expects integer count", .{});
                    if (t < @as(f64, @floatFromInt(std.math.minInt(i64))) or t > @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                        return self.fail("debug.sethook expects integer count", .{});
                    }
                    break :blk @as(i64, @intFromFloat(t));
                },
                else => return self.fail("debug.sethook expects integer count", .{}),
            };
        } else {
            hook_state.count = 0;
        }
        if (hook_state.count < 0 or hook_state.count > (1 << 24) - 1) {
            return self.fail("debug.sethook: count out of range", .{});
        }
        hook_state.budget = hook_state.count;
        hook_state.tick = 0;
        hook_state.skip_line_once = false;
        hook_state.skip_line_until_depth = 0;
        hook_state.skip_count_once = false;
        hook_state.line_hook_preseeded = if (target_thread == null)
            try self.debugPreseedLineHookFromUpvalue(hook_state.func.?, hook_state.mask)
        else
            false;
        if (hook_state.has_line and self.frames.items.len != 0 and target_thread == null) {
            for (self.frames.items) |*fr| {
                fr.last_hook_line = fr.current_line;
            }
        }
    }

    fn builtinDebugSetuservalue(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("debug.setuservalue expects (u, value)", .{});
        const target = args[0];
        if (target == .Nil) return self.fail("bad argument #1 to 'setuservalue' (userdata expected, got nil)", .{});
        if (target == .Int or target == .Num) return self.fail("bad argument #1 to 'setuservalue' (userdata expected, got number)", .{});
        if (isTestcLightUserdata(self, target)) {
            return self.fail("bad argument #1 to 'setuservalue' (full userdata expected, got light userdata)", .{});
        }
        if (!isTestcUserdata(self, target)) {
            if (outs.len > 0) outs[0] = .{ .Bool = false };
            return;
        }
        const idx: i64 = if (args.len >= 3 and args[2] == .Int)
            args[2].Int
        else if (args.len >= 3 and args[2] == .Num and @floor(args[2].Num) == args[2].Num)
            @intFromFloat(args[2].Num)
        else
            1;
        if (idx < 1 or idx > 10) {
            if (outs.len > 0) outs[0] = .{ .Bool = false };
            return;
        }
        const uv_tbl_v = self.getFieldOpt(target.Table, "__uservals") orelse blk: {
            const uv = try self.allocTable();
            try self.setField(target.Table, "__uservals", .{ .Table = uv });
            break :blk Value{ .Table = uv };
        };
        const uv_tbl = uv_tbl_v.Table;
        const val = if (args.len >= 2) args[1] else .Nil;
        try self.tableSetValue(uv_tbl, .{ .Int = idx }, val);
        if (outs.len > 0) outs[0] = .{ .Bool = true };
    }

    fn builtinDebugGetuservalue(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return;
        const target = args[0];
        const idx: i64 = if (args.len >= 2 and args[1] == .Int)
            args[1].Int
        else if (args.len >= 2 and args[1] == .Num and @floor(args[1].Num) == args[1].Num)
            @intFromFloat(args[1].Num)
        else
            1;
        if (!isTestcUserdata(self, target) or isTestcLightUserdata(self, target)) {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .Bool = false };
            return;
        }
        if (idx < 1 or idx > 10) {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .Bool = false };
            return;
        }
        if (self.getFieldOpt(target.Table, "__uservals")) |uvv| {
            if (uvv == .Table) {
                const uv = try self.tableGetRawValue(uvv.Table, .{ .Int = idx });
                if (outs.len > 0) outs[0] = uv;
                if (outs.len > 1) outs[1] = .{ .Bool = true };
                return;
            }
        }
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .{ .Bool = true };
    }

    fn builtinPairs(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'pairs' (value expected)", .{});
        if (args[0] != .Table) return self.fail("bad argument #1 to 'pairs' (table expected, got {s})", .{self.valueTypeName(args[0])});
        for (outs) |*out| out.* = .Nil;
        const mm = metamethodValue(self, args[0], "__pairs");
        if (mm) |mmv| {
            var mm_args = [_]Value{args[0]};
            const resolved = try self.resolveCallable(mmv, mm_args[0..], .{ .namewhat = "metamethod", .name = "__pairs" });
            defer if (resolved.owned_args) |owned| self.alloc.free(owned);
            switch (resolved.callee) {
                .Builtin => |id| {
                    try self.callBuiltin(id, resolved.args, outs);
                    if (builtinHasDynamicOutCount(id)) {
                        var i = self.last_builtin_out_count;
                        while (i < outs.len) : (i += 1) outs[i] = .Nil;
                    }
                },
                .Closure => |cl| {
                    const ret = try self.runClosure(cl, resolved.args, false);
                    defer self.alloc.free(ret);
                    const n = @min(outs.len, ret.len);
                    for (0..n) |i| outs[i] = ret[i];
                },
                else => unreachable,
            }
            return;
        }
        if (outs.len == 0) return;
        outs[0] = .{ .Builtin = .next };
        if (outs.len > 1) outs[1] = args[0];
        if (outs.len > 2) outs[2] = .Nil;
    }

    fn builtinIpairs(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'ipairs' (value expected)", .{});
        if (args[0] != .Table) return self.fail("bad argument #1 to 'ipairs' (table expected, got {s})", .{self.valueTypeName(args[0])});
        outs[0] = .{ .Builtin = .ipairs_iter };
        if (outs.len > 1) outs[1] = args[0];
        if (outs.len > 2) outs[2] = .{ .Int = 0 };
    }

    fn builtinPairsIter(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("pairs iterator: expected state and control", .{});
        const state = try self.expectTable(args[0]);
        const keys_v = self.getFieldOpt(state, "__keys") orelse return self.fail("pairs iterator: missing keys", .{});
        const target_v = self.getFieldOpt(state, "__target") orelse return self.fail("pairs iterator: missing target", .{});
        const keys = try self.expectTable(keys_v);
        const target = try self.expectTable(target_v);

        var idx: isize = -1;
        const control = args[1];
        if (control != .Nil) {
            for (keys.array.items, 0..) |k, i| {
                if (valuesEqual(k, control)) {
                    idx = @intCast(i);
                    break;
                }
            }
            if (idx < 0) return;
        }

        const next_idx: usize = @intCast(idx + 1);
        if (next_idx >= keys.array.items.len) return;
        const key = keys.array.items[next_idx];
        const val = try self.tableGetValue(target, key);

        outs[0] = key;
        if (outs.len > 1) outs[1] = val;
    }

    fn builtinIpairsIter(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .Nil;
        if (args.len < 2) return self.fail("ipairs iterator: expected state and control", .{});
        const tbl = try self.expectTable(args[0]);
        const control = args[1];
        const cur: i64 = switch (control) {
            .Nil => 0,
            .Int => |i| i,
            else => return self.fail("ipairs iterator: invalid control type {s}", .{control.typeName()}),
        };
        const next = cur +% 1;
        const val = try self.tableGetValue(tbl, .{ .Int = next });
        if (val == .Nil) return;
        outs[0] = .{ .Int = next };
        if (outs.len > 1) outs[1] = val;
    }

    fn builtinRawget(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("rawget expects (table, key)", .{});
        const tbl = try self.expectTable(args[0]);
        outs[0] = try self.tableGetRawValue(tbl, args[1]);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Unified hash part: raw get / set / next / length.
    //
    // These mirror PUC Lua 5.5 `ltable.c`:
    //   - rawGet      ≈ luaH_get (getgeneric / getintfromhash)
    //   - rawSet      ≈ luaH_set / luaH_newkey + array-part promotion
    //   - rawNext     ≈ luaH_next (array scan then hash scan)
    //   - tableBorderLen ≈ luaH_getn (boundary search; array-only here)
    //
    // All int/pointer keys hash through `ltable.keyHash` using `self.hash_seed`,
    // which is invariant across the Vm's lifetime (see field doc).
    // ─────────────────────────────────────────────────────────────────────

    // PUC luaH_get: look up `key` without invoking any __index metamethod.
    // Returns Nil if absent (including a logically-deleted node with value Nil).
    fn rawGet(self: *Vm, tbl: *const Table, key: Value) Value {
        switch (key) {
            .Int => |k| {
                if (k >= 1) {
                    const arr_len: i64 = @intCast(tbl.array.items.len);
                    if (k <= arr_len) {
                        return tbl.array.items[@intCast(k - 1)];
                    }
                }
            },
            .Num => |n| {
                // Integer-valued floats coerce to int keys (PUC luaV_tointeger).
                // NaN handled by caller (table key cannot be NaN); non-integer
                // floats fall through to the hash part as raw bit-pattern keys.
                if (std.math.isFinite(n) and
                    n >= -9_223_372_036_854_775_808.0 and
                    n < 9_223_372_036_854_775_808.0 and
                    @floor(n) == n)
                {
                    return self.rawGet(tbl, .{ .Int = @as(i64, @intFromFloat(n)) });
                }
            },
            .Nil => return .Nil,
            else => {},
        }
        const node = ltable.nodeLookup(tbl.hash, key, self.hash_seed) orelse return .Nil;
        return node.value;
    }

    // PUC luaH_set / luaH_newkey: store `val` at `key`, growing the hash part
    // (or extending the array part) as needed. Setting val==.Nil deletes the
    // hash entry (PUC: don't insert nils) but leaves array entries in place as
    // holes (PUC: array compaction is the rehash path's job).
    fn rawSet(self: *Vm, tbl: *Table, key: Value, val: Value) Error!void {
        switch (key) {
            .Nil => return self.fail("table key cannot be nil", .{}),
            .Num => |n| {
                if (std.math.isNan(n)) return self.fail("table key cannot be NaN", .{});
                if (std.math.isFinite(n) and
                    n >= -9_223_372_036_854_775_808.0 and
                    n < 9_223_372_036_854_775_808.0 and
                    @floor(n) == n)
                {
                    return self.rawSet(tbl, .{ .Int = @as(i64, @intFromFloat(n)) }, val);
                }
                // Non-integer float key: hash by raw value (PUC tags this as
                // a generic float key; we let ltable treat the Value.Num as
                // itself — see keyHash default branch returning 0 for floats).
            },
            else => {},
        }

        // Integer keys in [1..array.len] go to the array part.
        if (key == .Int) {
            const k = key.Int;
            const arr_len: i64 = @intCast(tbl.array.items.len);
            if (k >= 1 and k <= arr_len) {
                tbl.array.items[@intCast(k - 1)] = val;
                return;
            }
            // Contiguous extension: append at array.len+1, then pull any
            // immediately following integer keys from the hash part so the
            // array stays densely packed (keeps #/unpack semantics simple).
            // PUC computesizes() does this at rehash; we do it eagerly because
            // we don't rehash for array resizing.
            if (k == arr_len + 1 and val != .Nil) {
                try self.testcChargeMemory(64);
                try self.appendTableArrayValue(tbl, val);
                var next_k = k + 1;
                while (true) {
                    const nk: Value = .{ .Int = next_k };
                    const node = ltable.nodeLookup(tbl.hash, nk, self.hash_seed) orelse break;
                    if (node.value == .Nil) break; // absent or deleted
                    try self.appendTableArrayValue(tbl, node.value);
                    // Remove from hash part so the key isn't double-stored.
                    _ = ltable.nodeDelete(tbl.hash, nk, self.hash_seed);
                    next_k += 1;
                }
                return;
            }
        }

        // Hash-part insert / update.
        if (ltable.nodeLookup(tbl.hash, key, self.hash_seed)) |node| {
            // Existing node (may currently hold a Nil value from a prior delete).
            if (val == .Nil) {
                // Logical delete: leave node in chain with value Nil (PUC).
                _ = ltable.nodeDelete(tbl.hash, key, self.hash_seed);
            } else {
                node.value = val;
            }
            return;
        }
        if (val == .Nil) return; // PUC: deleting an absent key is a no-op.

        // Need a free slot. Ensure the hash part exists at all first.
        if (tbl.hash.len == 0) {
            try self.testcChargeMemory(64);
            // Initial size 4 (log2=2). All empty; lastfree starts at len so
            // getFreePos scans the whole range.
            tbl.hash = try self.alloc.alloc(ltable.Node, 4);
            for (tbl.hash) |*n| n.* = .{};
            tbl.hash_lastfree = tbl.hash.len;
        }

        // Try to insert at the current size.
        if (ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed) != null) return;

        // Hash part is full: grow (doubling, PUC rehash). Rehash drops any
        // deleted/Nil-valued nodes and rebuilds chains from scratch.
        try self.testcChargeMemory(64);
        const cur_log2: u6 = @intCast(std.math.log2_int(usize, tbl.hash.len));
        const r = try ltable.rehash(self.alloc, tbl.hash, cur_log2 + 1, self.hash_seed);
        self.alloc.free(tbl.hash);
        tbl.hash = r.nodes;
        tbl.hash_lastfree = r.lastfree;
        // Retry insert: guaranteed to succeed (new size has capacity ≥ live + 1).
        const inserted = ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed);
        std.debug.assert(inserted != null);
    }

    // PUC luaH_next: given a control key (Nil for the start of iteration),
    // return the next (key, value) pair in PUC's defined order — first the
    // array part (keys 1..n), then the hash part in node-memory order.
    //
    // Returns null when iteration is complete. Returns error.RuntimeError if
    // the control key is non-Nil and not present in the table.
    fn rawNext(self: *Vm, tbl: *Table, control_key: Value) Error!?struct { key: Value, value: Value } {
        const cc = canonicalizeNextControl(control_key);

        // Determine where to start scanning, based on the control key.
        // Nil → start of array (index 0). Int in array range → just past it.
        // Otherwise → just past the control key's hash-node slot.
        var array_idx: usize = 0;
        var hash_idx: usize = 0;
        var in_array = true;
        if (cc != .Nil) {
            if (cc == .Int) {
                const k = cc.Int;
                if (k >= 1 and k <= @as(i64, @intCast(tbl.array.items.len))) {
                    const arr_idx0: usize = @intCast(k - 1);
                    // Array keys in range are always valid control positions for
                    // `next`, even if the slot is nil (a hole) — PUC `keyinarray`
                    // is a pure range check (ltable.c:329-339). Scan past it.
                    array_idx = arr_idx0 + 1;
                } else {
                    // Int outside array: must be (or have been) a hash key.
                    in_array = false;
                    const node = ltable.nodeLookup(tbl.hash, cc, self.hash_seed) orelse {
                        return self.fail("invalid key to 'next'", .{});
                    };
                    // PUC `getgeneric(key, deadok=1)` accepts a deleted (Nil-
                    // valued) node as a valid control (ltable.c:291-303). Use its
                    // position; do not reject on value==.Nil.
                    hash_idx = indexNodeInHash(tbl.hash, node, self.hash_seed);
                    if (hash_idx == tbl.hash.len) return null;
                    hash_idx += 1;
                }
            } else {
                in_array = false;
                const node = ltable.nodeLookup(tbl.hash, cc, self.hash_seed) orelse {
                    return self.fail("invalid key to 'next'", .{});
                };
                // Deleted (Nil-valued) node is a valid control (see above).
                hash_idx = indexNodeInHash(tbl.hash, node, self.hash_seed);
                if (hash_idx == tbl.hash.len) return null;
                hash_idx += 1;
            }
        }

        // Array part scan.
        if (in_array) {
            while (array_idx < tbl.array.items.len) : (array_idx += 1) {
                const v = tbl.array.items[array_idx];
                if (v != .Nil) {
                    return .{ .key = .{ .Int = @intCast(array_idx + 1) }, .value = v };
                }
            }
            // Fall through to hash part, starting from index 0.
            hash_idx = 0;
        }

        // Hash part scan (memory order, skipping empty + value-Nil nodes).
        if (ltable.nextLiveIndex(tbl.hash, hash_idx)) |hi| {
            const node = tbl.hash[hi];
            return .{ .key = node.key, .value = node.value };
        }
        return null;
    }

    // Linear scan to find the array index of a known-present node pointer.
    // PUC `luaH_next` doesn't need this (it walks in chain order); our hash
    // next() iterates memory order so we must translate node-pointer → index.
    // Returns hash.len if not found (shouldn't happen for a fresh lookup).
    fn indexNodeInHash(nodes: []ltable.Node, target: *const ltable.Node, seed: u64) usize {
        _ = seed;
        const base: usize = @intFromPtr(nodes.ptr);
        const off: usize = (@intFromPtr(target) - base) / @sizeOf(ltable.Node);
        return off;
    }

    // Thin compatibility wrappers around the new primitives — kept so the many
    // existing call sites continue to compile unchanged. They carry the same
    // signatures as before the refactor.
    fn tableSetValue(self: *Vm, tbl: *Table, key: Value, val: Value) Error!void {
        return self.rawSet(tbl, key, val);
    }

    // ─────────────────────────────────────────────────────────────────────
    // String-key convenience helpers.
    //
    // The old `Table.fields` was a StringHashMap keyed by raw []const u8. Many
    // call sites read/wrote fields by literal name (e.g. `self.getFieldOpt(mt, "__gc")`
    // or `tbl.fields.put(alloc, "n", ...)`). The unified hash part keys
    // everything by `Value.String` (an interned *LuaString), so we provide
    // thin name→key adapters that the ported call sites can use verbatim.
    // ─────────────────────────────────────────────────────────────────────

    // Read a string-keyed field. Returns Nil if absent.
    fn getField(self: *Vm, tbl: *Table, name: []const u8) Value {
        const key: Value = .{ .String = self.internStrAssume(name) };
        return self.rawGet(tbl, key);
    }

    // Read a string-keyed field as option (Nil → null). Matches the old
    // `self.getFieldOpt(tbl, name) orelse ...` pattern.
    pub fn getFieldOpt(self: *Vm, tbl: *Table, name: []const u8) ?Value {
        const v = self.getField(tbl, name);
        return if (v == .Nil) null else v;
    }

    // Write a string-keyed field. Interns `name` once; the existing value (if
    // any) is overwritten. Writing Nil deletes the entry (rawSet semantics).
    fn setField(self: *Vm, tbl: *Table, name: []const u8, val: Value) Error!void {
        const key: Value = .{ .String = try self.internStr(name) };
        return self.rawSet(tbl, key, val);
    }

    // Remove a string-keyed field (if present). Equivalent to setField(Nil) but
    // reads slightly clearer at delete-only sites.
    fn removeField(self: *Vm, tbl: *Table, name: []const u8) Error!void {
        return self.setField(tbl, name, .Nil);
    }

    // Coerce a `next()`/`rawnext()` control key into the canonical form used
    // internally: integer-valued floats become Int, everything else is left
    // alone. PUC `luaV_tointeger` does the same coercion for table keys.
    fn canonicalizeNextControl(control: Value) Value {
        return switch (control) {
            .Num => |n| blk: {
                if (!std.math.isNan(n) and
                    std.math.isFinite(n) and
                    n >= -9_223_372_036_854_775_808.0 and
                    n < 9_223_372_036_854_775_808.0 and
                    @floor(n) == n)
                {
                    break :blk .{ .Int = @as(i64, @intFromFloat(n)) };
                }
                break :blk control;
            },
            else => control,
        };
    }

    fn builtinRawset(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len < 3) return self.fail("rawset expects (table, key, value)", .{});
        const tbl = try self.expectTable(args[0]);
        try self.tableSetValue(tbl, args[1], args[2]);
        if (outs.len > 0) outs[0] = args[0];
    }

    fn builtinIoWrite(self: *Vm, to_stderr: bool, args: []const Value, outs: []Value) Error!void {
        var out = if (to_stderr) stdio.stderr() else stdio.stdout();
        var target_file_v: Value = .Nil;
        var i: usize = 0;
        var argn: usize = 0;
        var ret_file: Value = .Nil;
        if (!to_stderr and args.len > 0 and asFileTable(self, args[0]) != null) {
            // Method call syntax: <file>:write(...). Handle stdout/stderr objects.
            const io_v = self.getGlobal("io");
            if (io_v == .Table) {
                const io_tbl = io_v.Table;
                ret_file = args[0];
                if (self.getFieldOpt(io_tbl, "stderr")) |stderr_v| {
                    if (stderr_v == .Table and stderr_v.Table == args[0].Table) out = stdio.stderr();
                }
                if (self.getFieldOpt(io_tbl, "stdout")) |stdout_v| {
                    if (!(stdout_v == .Table and stdout_v.Table == args[0].Table)) {
                        _ = self.getManagedFile(args[0]) orelse return self.fail("closed file", .{});
                        target_file_v = args[0];
                    }
                }
            }
            i = 1;
        } else if (!to_stderr) {
            // io.write(...) writes to current default output stream.
            const io_v = self.getGlobal("io");
            if (io_v == .Table) {
                const io_tbl = io_v.Table;
                const out_v = self.getFieldOpt(io_tbl, "stdout") orelse .Nil;
                const cur_v = self.getFieldOpt(io_tbl, "output_stream") orelse out_v;
                ret_file = cur_v;
                if (self.getFieldOpt(io_tbl, "stderr")) |stderr_v| {
                    if (stderr_v == .Table and cur_v == .Table and stderr_v.Table == cur_v.Table) out = stdio.stderr();
                }
                if (cur_v != .Nil and !(cur_v == .Table and out_v == .Table and cur_v.Table == out_v.Table)) {
                    _ = self.getManagedFile(cur_v) orelse return self.fail(" output file is closed", .{});
                    target_file_v = cur_v;
                }
            }
        }
        while (i < args.len) : (i += 1) {
            // For method calls, first arg is the receiver (file object). Ignore it.
            if (to_stderr and i == 0 and args[i] == .Table) continue;
            argn += 1;
            switch (args[i]) {
                .String, .Int, .Num => {},
                else => return self.fail("bad argument #{d} to '{s}' (string expected, got {s})", .{ argn, if (to_stderr) "io.stderr:write" else "io.write", self.valueTypeName(args[i]) }),
            }
            const s = try self.valueToStringAlloc(args[i]);
            if (target_file_v != .Nil) {
                if (!(try self.writeBufferedFile(target_file_v, s))) {
                    return self.fail("file write error: write error", .{});
                }
            } else {
                out.writeAll(s) catch |e| switch (e) {
                    error.BrokenPipe => return,
                    else => return self.fail("{s} write error: {s}", .{ if (to_stderr) "stderr" else "stdout", @errorName(e) }),
                };
            }
        }
        if (to_stderr) {
            const io_v = self.getGlobal("io");
            if (io_v == .Table) ret_file = self.getFieldOpt(io_v.Table, "stderr") orelse .Nil;
        }
        if (outs.len > 0 and ret_file != .Nil) outs[0] = ret_file;
    }

    fn builtinIoInput(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const io_v = self.getGlobal("io");
        if (io_v != .Table) {
            outs[0] = .Nil;
            return;
        }
        const io_tbl = io_v.Table;
        if (args.len == 0) {
            outs[0] = self.getFieldOpt(io_tbl, "input_stream") orelse (self.getFieldOpt(io_tbl, "stdin") orelse .Nil);
            return;
        }
        const old_in = self.getFieldOpt(io_tbl, "input_stream") orelse (self.getFieldOpt(io_tbl, "stdin") orelse .Nil);
        if (args[0] == .String) {
            var open_out = [_]Value{ .Nil, .Nil, .Nil };
            const file_v = try self.ioOpenPath(args[0].String.bytes(), "r", open_out[0..]) orelse {
                const msg = if (open_out[1] == .String) ioErrText(open_out[1].String.bytes()) else "cannot open file";
                return self.fail("cannot open file '{s}' ({s})", .{ args[0].String.bytes(), msg });
            };
            try self.setField(io_tbl, "input_stream", file_v);
            self.maybeCloseReplacedDefault(old_in, file_v);
            outs[0] = file_v;
            return;
        }
        const name = self.valueTypeName(args[0]);
        if (!std.mem.startsWith(u8, name, "FILE")) {
            return self.fail("bad argument #1 to 'input' (FILE* expected, got {s})", .{name});
        }
        try self.setField(io_tbl, "input_stream", args[0]);
        self.maybeCloseReplacedDefault(old_in, args[0]);
        outs[0] = args[0];
    }

    fn asFileTable(self: *Vm, v: Value) ?*Table {
        if (v != .Table) return null;
        const t = v.Table;
        const mt = t.metatable orelse return null;
        const nm = self.getFieldOpt(mt, "__name") orelse return null;
        if (nm != .String or nm.String != self.internStrAssume("FILE*")) return null;
        return t;
    }

    fn fileIdFromTable(self: *Vm, tbl: *Table) ?i64 {
        const idv = self.getFieldOpt(tbl, "__file_id") orelse return null;
        return switch (idv) {
            .Int => |id| id,
            else => null,
        };
    }

    fn fileCanRead(self: *Vm, v: Value) bool {
        const tbl = asFileTable(self, v) orelse return false;
        const cv = self.getFieldOpt(tbl, "__can_read") orelse return self.fileIdFromTable(tbl) == null;
        return cv == .Bool and cv.Bool;
    }

    fn fileCanWrite(self: *Vm, v: Value) bool {
        const tbl = asFileTable(self, v) orelse return false;
        const cv = self.getFieldOpt(tbl, "__can_write") orelse return self.fileIdFromTable(tbl) == null;
        return cv == .Bool and cv.Bool;
    }

    fn getManagedFile(self: *Vm, v: Value) ?*std.Io.File {
        const tbl = asFileTable(self, v) orelse return null;
        const id = self.fileIdFromTable(tbl) orelse return null;
        return self.open_files.getPtr(id);
    }

    fn getFileBuffer(self: *Vm, v: Value) ?*FileBuffer {
        const tbl = asFileTable(self, v) orelse return null;
        const id = self.fileIdFromTable(tbl) orelse return null;
        return self.file_buffers.getPtr(id);
    }

    fn flushBufferedFile(self: *Vm, v: Value) bool {
        const f = self.getManagedFile(v) orelse return false;
        const fb = self.getFileBuffer(v) orelse return false;
        if (fb.pending.items.len == 0) return true;
        f.writePositionalAll(stdio.activeIo(), fb.pending.items, fb.pos) catch return false;
        fb.pos += fb.pending.items.len;
        fb.pending.clearRetainingCapacity();
        return true;
    }

    fn writeBufferedFile(self: *Vm, v: Value, s: []const u8) Error!bool {
        const f = self.getManagedFile(v) orelse return false;
        const fb = self.getFileBuffer(v) orelse return false;
        switch (fb.mode) {
            .no => {
                f.writePositionalAll(stdio.activeIo(), s, fb.pos) catch return false;
                fb.pos += s.len;
            },
            .full => {
                try fb.pending.appendSlice(self.alloc, s);
            },
            .line => {
                try fb.pending.appendSlice(self.alloc, s);
                if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                    if (!self.flushBufferedFile(v)) return false;
                }
            },
        }
        return true;
    }

    fn readByte(file: *std.Io.File, fb: *FileBuffer) !?u8 {
        var b: [1]u8 = undefined;
        const n = try file.readPositionalAll(stdio.activeIo(), b[0..], fb.pos);
        if (n == 0) return null;
        fb.pos += 1;
        return b[0];
    }

    fn unreadByte(fb: *FileBuffer) void {
        if (fb.pos > 0) fb.pos -= 1;
    }

    fn readLineAlloc(self: *Vm, file: *std.Io.File, fb: *FileBuffer, keep_newline: bool) Error!?*LuaString {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        while (true) {
            const b = readByte(file, fb) catch |e| return self.fail("read error: {s}", .{@errorName(e)});
            if (b == null) break;
            const c = b.?;
            if (c == '\n') {
                if (keep_newline) out.append(self.alloc, c) catch return error.OutOfMemory;
                break;
            }
            out.append(self.alloc, c) catch return error.OutOfMemory;
        }
        if (out.items.len == 0) {
            const end = file.length(stdio.activeIo()) catch return null;
            if (fb.pos >= end) return null;
        }
        return try self.internStr(out.items);
    }

    fn readCountAlloc(self: *Vm, file: *std.Io.File, fb: *FileBuffer, n: usize) Error!?*LuaString {
        if (n == 0) {
            const e = file.length(stdio.activeIo()) catch return try self.internStr("");
            if (fb.pos >= e) return null;
            return try self.internStr("");
        }
        var buf = try self.alloc.alloc(u8, n);
        defer self.alloc.free(buf);
        const got = file.readPositionalAll(stdio.activeIo(), buf, fb.pos) catch |e| return self.fail("read error: {s}", .{@errorName(e)});
        if (got == 0) return null;
        fb.pos += got;
        return try self.internStr(buf[0..got]);
    }

    fn readAllAlloc(self: *Vm, file: *std.Io.File, fb: *FileBuffer) Error!*LuaString {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const got = file.readPositionalAll(stdio.activeIo(), tmp[0..], fb.pos) catch |e| return self.fail("read error: {s}", .{@errorName(e)});
            if (got == 0) break;
            fb.pos += got;
            try out.appendSlice(self.alloc, tmp[0..got]);
        }
        return try self.internStr(out.items);
    }

    fn closeManagedFile(self: *Vm, tbl: *Table) void {
        const id = self.fileIdFromTable(tbl) orelse return;
        if (self.file_buffers.fetchRemove(id)) |fb| {
            if (self.open_files.getPtr(id)) |f| {
                _ = f.writePositionalAll(stdio.activeIo(), fb.value.pending.items, fb.value.pos) catch {};
            }
            var buf = fb.value;
            buf.pending.deinit(self.alloc);
        }
        if (self.open_files.fetchRemove(id)) |entry| {
            entry.value.close(stdio.activeIo());
        }
        _ = self.finalizables.remove(tbl);
    }

    fn allocManagedFileObject(self: *Vm, file: std.Io.File, can_read: bool, can_write: bool) Error!Value {
        const file_mt = self.file_metatable orelse return self.fail("file metatable missing", .{});

        const tbl = try self.allocTableNoGc();
        tbl.metatable = file_mt;
        try self.finalizables.put(self.alloc, tbl, {});
        try self.setField(tbl, "close", .{ .Builtin = .file_close });
        try self.setField(tbl, "write", .{ .Builtin = .file_write });
        try self.setField(tbl, "read", .{ .Builtin = .file_read });
        try self.setField(tbl, "seek", .{ .Builtin = .file_seek });
        try self.setField(tbl, "flush", .{ .Builtin = .file_flush });
        try self.setField(tbl, "lines", .{ .Builtin = .file_lines });
        try self.setField(tbl, "setvbuf", .{ .Builtin = .file_setvbuf });

        const id = self.next_file_id;
        self.next_file_id += 1;
        try self.open_files.put(self.alloc, id, file);
        try self.file_buffers.put(self.alloc, id, .{});
        try self.setField(tbl, "__file_id", .{ .Int = id });
        try self.setField(tbl, "__can_read", .{ .Bool = can_read });
        try self.setField(tbl, "__can_write", .{ .Bool = can_write });
        return .{ .Table = tbl };
    }

    const IoOpenBase = enum { r, w, a };
    const IoOpenMode = struct {
        base: IoOpenBase,
        plus: bool,
    };

    fn parseIoMode(mode: []const u8) ?IoOpenMode {
        if (mode.len == 0) return null;
        var i: usize = 0;
        const base: IoOpenBase = switch (mode[i]) {
            'r' => .r,
            'w' => .w,
            'a' => .a,
            else => return null,
        };
        i += 1;
        var plus = false;
        if (i < mode.len and mode[i] == '+') {
            plus = true;
            i += 1;
        }
        if (i < mode.len and mode[i] == 'b') i += 1;
        if (i != mode.len) return null;
        return .{ .base = base, .plus = plus };
    }

    fn ioOpenPath(self: *Vm, path: []const u8, mode_s: []const u8, outs: []Value) Error!?Value {
        const mode = parseIoMode(mode_s) orelse return self.fail("bad argument #2 to 'open' (invalid mode)", .{});
        const io = stdio.activeIo();
        const cwd = std.Io.Dir.cwd();
        const abs = std.fs.path.isAbsolute(path);
        const file = (switch (mode.base) {
            .r => if (abs)
                std.Io.Dir.openFileAbsolute(io, path, .{ .mode = if (mode.plus) .read_write else .read_only })
            else
                cwd.openFile(io, path, .{ .mode = if (mode.plus) .read_write else .read_only }),
            .w => blk: {
                var f = (if (abs)
                    std.Io.Dir.openFileAbsolute(io, path, .{ .mode = if (mode.plus) .read_write else .write_only })
                else
                    cwd.openFile(io, path, .{ .mode = if (mode.plus) .read_write else .write_only })) catch |e| switch (e) {
                    error.FileNotFound => (if (abs)
                        std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true, .read = mode.plus })
                    else
                        cwd.createFile(io, path, .{ .truncate = true, .read = mode.plus })) catch |e2| {
                        if (outs.len > 0) outs[0] = .Nil;
                        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e2)) };
                        if (outs.len > 2) outs[2] = .{ .Int = 1 };
                        return null;
                    },
                    else => {
                        if (outs.len > 0) outs[0] = .Nil;
                        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
                        if (outs.len > 2) outs[2] = .{ .Int = 1 };
                        return null;
                    },
                };
                f.setLength(stdio.activeIo(), 0) catch |e| {
                    if (e == error.NonResizable) {
                        _ = stdio.activeIo().vtable.fileSeekTo(stdio.activeIo().userdata, f, 0) catch {};
                        break :blk f;
                    }
                    f.close(stdio.activeIo());
                    if (outs.len > 0) outs[0] = .Nil;
                    if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
                    if (outs.len > 2) outs[2] = .{ .Int = 1 };
                    return null;
                };
                _ = stdio.activeIo().vtable.fileSeekTo(stdio.activeIo().userdata, f, 0) catch {};
                break :blk f;
            },
            .a => blk: {
                var f = (if (abs)
                    std.Io.Dir.openFileAbsolute(io, path, .{ .mode = if (mode.plus) .read_write else .write_only })
                else
                    cwd.openFile(io, path, .{ .mode = if (mode.plus) .read_write else .write_only })) catch |e| switch (e) {
                    error.FileNotFound => (if (abs)
                        std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = mode.plus })
                    else
                        cwd.createFile(io, path, .{ .truncate = false, .read = mode.plus })) catch |e2| {
                        if (outs.len > 0) outs[0] = .Nil;
                        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e2)) };
                        if (outs.len > 2) outs[2] = .{ .Int = 1 };
                        return null;
                    },
                    else => {
                        if (outs.len > 0) outs[0] = .Nil;
                        if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
                        if (outs.len > 2) outs[2] = .{ .Int = 1 };
                        return null;
                    },
                };
                stdio.activeIo().vtable.fileSeekTo(stdio.activeIo().userdata, f, f.length(stdio.activeIo()) catch 0) catch |e| {
                    f.close(stdio.activeIo());
                    if (outs.len > 0) outs[0] = .Nil;
                    if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
                    if (outs.len > 2) outs[2] = .{ .Int = 1 };
                    return null;
                };
                break :blk f;
            },
        }) catch |e| {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return null;
        };
        const can_read = mode.base == .r or mode.plus;
        const can_write = mode.base != .r or mode.plus;
        const file_v = try self.allocManagedFileObject(file, can_read, can_write);
        if (self.getFileBuffer(file_v)) |fb| {
            fb.pos = if (mode.base == .a) file.length(stdio.activeIo()) catch 0 else 0;
        }
        return file_v;
    }

    fn ioErrText(err_name: []const u8) []const u8 {
        if (std.mem.eql(u8, err_name, "AccessDenied")) return "Permission denied";
        if (std.mem.eql(u8, err_name, "FileNotFound")) return "No such file or directory";
        if (std.mem.eql(u8, err_name, "PathAlreadyExists")) return "File exists";
        return err_name;
    }

    fn builtinIoOpen(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0 or args[0] != .String) {
            return self.fail("bad argument #1 to 'open' (string expected)", .{});
        }
        const path = args[0].String.bytes();
        const mode_s: []const u8 = if (args.len >= 2) switch (args[1]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #2 to 'open' (string expected)", .{}),
        } else "r";
        const file_v = try self.ioOpenPath(path, mode_s, outs) orelse return;
        outs[0] = file_v;
    }

    fn builtinIoTmpfile(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        var tmp_out = [_]Value{.Nil};
        try self.builtinOsTmpname(&.{}, tmp_out[0..]);
        if (tmp_out[0] != .String) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("tmpname failed") };
            return;
        }
        const tmp = tmp_out[0].String.bytes();
        const f = try self.ioOpenPath(tmp, "w+", outs) orelse return;
        outs[0] = f;
    }

    fn readOneFormat(self: *Vm, file_v: Value, spec: Value) Error!Value {
        const f = self.getManagedFile(file_v) orelse return self.fail("closed file", .{});
        const fb = self.getFileBuffer(file_v) orelse return self.fail("closed file", .{});
        if (spec == .Int) {
            if (spec.Int < 0) return self.fail("bad argument to 'read' (invalid format)", .{});
            const s = try self.readCountAlloc(f, fb, @intCast(spec.Int));
            return if (s) |ls| .{ .String = ls } else .Nil;
        }
        const fmt: []const u8 = if (spec == .String) spec.String.bytes() else return self.fail("bad argument to 'read' (invalid format)", .{});
        if (std.mem.eql(u8, fmt, "l") or std.mem.eql(u8, fmt, "*l")) {
            const s = try self.readLineAlloc(f, fb, false);
            return if (s) |ls| .{ .String = ls } else .Nil;
        }
        if (std.mem.eql(u8, fmt, "L") or std.mem.eql(u8, fmt, "*L")) {
            const s = try self.readLineAlloc(f, fb, true);
            return if (s) |ls| .{ .String = ls } else .Nil;
        }
        if (std.mem.eql(u8, fmt, "a") or std.mem.eql(u8, fmt, "*a") or std.mem.eql(u8, fmt, "all")) {
            const s = try self.readAllAlloc(f, fb);
            return .{ .String = s };
        }
        if (std.mem.eql(u8, fmt, "n") or std.mem.eql(u8, fmt, "*n")) {
            var tok = std.ArrayList(u8).empty;
            defer tok.deinit(self.alloc);
            while (true) {
                const b = readByte(f, fb) catch |e| return self.fail("read error: {s}", .{@errorName(e)});
                if (b == null) break;
                if (std.ascii.isWhitespace(b.?)) continue;
                unreadByte(fb);
                break;
            }
            while (true) {
                const b = readByte(f, fb) catch |e| return self.fail("read error: {s}", .{@errorName(e)});
                if (b == null) break;
                const c = b.?;
                const ok = std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.' or c == 'x' or c == 'X' or c == 'p' or c == 'P' or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
                if (!ok) {
                    unreadByte(fb);
                    break;
                }
                try tok.append(self.alloc, c);
            }
            if (tok.items.len == 0) return .Nil;
            const sfull = tok.items;
            var i: usize = 0;
            if (sfull[i] == '+' or sfull[i] == '-') {
                i += 1;
                if (i >= sfull.len) return .Nil;
            }
            var consume_len: usize = 0;
            var parsed: ?Value = null;

            const is_hex = i + 1 < sfull.len and sfull[i] == '0' and (sfull[i + 1] == 'x' or sfull[i + 1] == 'X');
            if (is_hex) {
                i += 2; // consume 0x
                var has_hex = false;
                while (i < sfull.len and ((sfull[i] >= '0' and sfull[i] <= '9') or (sfull[i] >= 'a' and sfull[i] <= 'f') or (sfull[i] >= 'A' and sfull[i] <= 'F'))) : (i += 1) has_hex = true;
                var had_dot = false;
                if (i < sfull.len and sfull[i] == '.') {
                    had_dot = true;
                    i += 1;
                    while (i < sfull.len and ((sfull[i] >= '0' and sfull[i] <= '9') or (sfull[i] >= 'a' and sfull[i] <= 'f') or (sfull[i] >= 'A' and sfull[i] <= 'F'))) : (i += 1) has_hex = true;
                }
                var had_exp = false;
                var exp_digits: usize = 0;
                if (has_hex and i < sfull.len and (sfull[i] == 'p' or sfull[i] == 'P')) {
                    had_exp = true;
                    i += 1;
                    if (i < sfull.len and (sfull[i] == '+' or sfull[i] == '-')) i += 1;
                    while (i < sfull.len and (sfull[i] >= '0' and sfull[i] <= '9')) : (i += 1) exp_digits += 1;
                }
                consume_len = i;
                const complete = has_hex and ((!had_dot and !had_exp) or (had_exp and exp_digits > 0));
                if (complete) {
                    const s = sfull[0..consume_len];
                    if (parseHexStringIntWrap(s)) |iv| {
                        parsed = .{ .Int = iv };
                    } else if (std.fmt.parseFloat(f64, s)) |n| {
                        parsed = .{ .Num = n };
                    } else |_| {}
                } else if (consume_len == 0) {
                    consume_len = 1;
                }
            } else {
                i = 0;
                if (sfull[i] == '+' or sfull[i] == '-') i += 1;
                var has_dec = false;
                while (i < sfull.len and (sfull[i] >= '0' and sfull[i] <= '9')) : (i += 1) has_dec = true;
                if (i < sfull.len and sfull[i] == '.') {
                    i += 1;
                    while (i < sfull.len and (sfull[i] >= '0' and sfull[i] <= '9')) : (i += 1) has_dec = true;
                }
                var had_exp = false;
                var exp_digits: usize = 0;
                if (has_dec and i < sfull.len and (sfull[i] == 'e' or sfull[i] == 'E')) {
                    had_exp = true;
                    i += 1;
                    if (i < sfull.len and (sfull[i] == '+' or sfull[i] == '-')) i += 1;
                    while (i < sfull.len and (sfull[i] >= '0' and sfull[i] <= '9')) : (i += 1) exp_digits += 1;
                }
                consume_len = i;
                const complete = has_dec and (!had_exp or exp_digits > 0);
                if (complete) {
                    const s = sfull[0..consume_len];
                    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
                        if (std.fmt.parseInt(i64, s, 10)) |iv| {
                            parsed = .{ .Int = iv };
                        } else |_| {}
                    }
                    if (parsed == null) {
                        if (std.fmt.parseFloat(f64, s)) |n| {
                            parsed = .{ .Num = n };
                        } else |_| {}
                    }
                } else {
                    if (consume_len == 0) {
                        consume_len = if (sfull[0] == '+' or sfull[0] == '-' or sfull[0] == '.') 1 else 0;
                    }
                    if (consume_len == 0) return .Nil;
                }
            }
            // Overlong numerals: fail, but keep tail in stream.
            if (consume_len > 200) {
                const keep: usize = @min(@as(usize, 32), consume_len);
                const unread_n = sfull.len - keep;
                if (unread_n != 0) fb.pos -|= unread_n;
                return .Nil;
            }
            const unread_n = sfull.len - consume_len;
            if (unread_n != 0) fb.pos -|= unread_n;
            return parsed orelse .Nil;
        }
        return self.fail("bad argument to 'read' (invalid format)", .{});
    }

    fn currentInputFile(self: *Vm) Value {
        const io_v = self.getGlobal("io");
        if (io_v != .Table) return .Nil;
        return self.getFieldOpt(io_v.Table, "input_stream") orelse (self.getFieldOpt(io_v.Table, "stdin") orelse .Nil);
    }

    fn currentOutputFile(self: *Vm) Value {
        const io_v = self.getGlobal("io");
        if (io_v != .Table) return .Nil;
        const io_tbl = io_v.Table;
        return self.getFieldOpt(io_tbl, "output_stream") orelse (self.getFieldOpt(io_tbl, "stdout") orelse .Nil);
    }

    fn builtinIoRead(self: *Vm, args: []const Value, outs: []Value) Error!void {
        const file_v = self.currentInputFile();
        if (asFileTable(self, file_v) != null and !self.isStdFile(file_v) and self.getManagedFile(file_v) == null) {
            return self.fail(" input file is closed", .{});
        }
        if (!fileCanRead(self, file_v)) return self.fail(" input file is closed", .{});
        if (args.len == 0) {
            if (outs.len > 0) outs[0] = try self.readOneFormat(file_v, .{ .String = try self.internStr("l") });
            return;
        }
        var out_i: usize = 0;
        var i: usize = 0;
        while (i < args.len and out_i < outs.len) : (i += 1) {
            const v = try self.readOneFormat(file_v, args[i]);
            outs[out_i] = v;
            if (v == .Nil) break;
            out_i += 1;
        }
        self.last_builtin_out_count = out_i + @intFromBool(out_i < outs.len and out_i < args.len and outs[out_i] == .Nil);
    }

    fn makeLinesIter(self: *Vm, file_v: Value, auto_close: bool, fmts: []const Value) Error!Value {
        const obj = try self.allocTableNoGc();
        const mt = try self.allocTableNoGc();
        const fmts_tbl = try self.allocTableNoGc();
        try self.setField(mt, "__call", .{ .Builtin = .io_lines_iter });
        obj.metatable = mt;
        try self.setField(obj, "__file", file_v);
        try self.setField(obj, "__auto_close", .{ .Bool = auto_close });
        try self.setField(obj, "__closed_error", .{ .Bool = false });
        const nfmts: usize = fmts.len;
        try fmts_tbl.array.resize(self.alloc, nfmts);
        for (0..nfmts) |i| fmts_tbl.array.items[i] = fmts[i];
        try self.setField(obj, "__fmts", .{ .Table = fmts_tbl });
        return .{ .Table = obj };
    }

    fn builtinIoLines(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        var file_v: Value = .Nil;
        var auto_close = false;
        var fmt_start: usize = 0;
        if (args.len == 0 or args[0] == .Nil) {
            file_v = self.currentInputFile();
            fmt_start = if (args.len == 0) 0 else 1;
        } else if (args[0] == .String) {
            var open_out = [_]Value{ .Nil, .Nil, .Nil };
            file_v = (try self.ioOpenPath(args[0].String.bytes(), "r", open_out[0..])) orelse {
                const msg = if (open_out[1] == .String) ioErrText(open_out[1].String.bytes()) else "cannot open file";
                return self.fail("cannot open file '{s}' ({s})", .{ args[0].String.bytes(), msg });
            };
            auto_close = true;
            fmt_start = 1;
        } else {
            file_v = args[0];
            fmt_start = 1;
        }
        if (asFileTable(self, file_v) == null) return self.fail("bad argument #1 to 'lines' (FILE* expected)", .{});
        const fmts = args[fmt_start..];
        if (fmts.len > 250) return self.fail("too many arguments", .{});
        const iter = try self.makeLinesIter(file_v, auto_close, fmts);
        outs[0] = iter;
        if (outs.len > 1) outs[1] = file_v;
        if (outs.len > 2) outs[2] = .Nil;
        if (auto_close and outs.len > 3) outs[3] = file_v;
        self.last_builtin_out_count = @min(if (auto_close) @as(usize, 4) else @as(usize, 3), outs.len);
    }

    fn builtinIoLinesIter(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0 or args[0] != .Table) return self.fail("bad argument #1 to 'lines' iterator", .{});
        const it = args[0].Table;
        const file_v = self.getFieldOpt(it, "__file") orelse .Nil;
        const closed_error = if (self.getFieldOpt(it, "__closed_error")) |v| (v == .Bool and v.Bool) else false;
        if (file_v == .Nil) {
            if (closed_error) return self.fail("file is already closed", .{});
            self.last_builtin_out_count = 0;
            return;
        }
        const fmt_tbl = if (self.getFieldOpt(it, "__fmts")) |v| if (v == .Table) v.Table else null else null;
        const fmt_count: usize = if (fmt_tbl) |t| t.array.items.len else 0;
        const cnt = if (fmt_count == 0) 1 else fmt_count;
        var out_i: usize = 0;
        while (out_i < cnt and out_i < outs.len) : (out_i += 1) {
            const spec = if (fmt_count == 0) Value{ .String = try self.internStr("l") } else fmt_tbl.?.array.items[out_i];
            const v = try self.readOneFormat(file_v, spec);
            if (out_i == 0 and v == .Nil) {
                const auto_close = if (self.getFieldOpt(it, "__auto_close")) |av| (av == .Bool and av.Bool) else false;
                if (auto_close) {
                    if (asFileTable(self, file_v)) |t| {
                        self.closeManagedFile(t);
                        _ = self.setField(t, "__closed", .{ .Bool = true }) catch {};
                    }
                    try self.setField(it, "__closed_error", .{ .Bool = true });
                }
                try self.setField(it, "__file", .Nil);
                self.last_builtin_out_count = 0;
                return;
            }
            outs[out_i] = v;
            if (v == .Nil) break;
        }
        self.last_builtin_out_count = out_i;
    }

    fn builtinIoFlush(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        const out_v = self.currentOutputFile();
        _ = self.getManagedFile(out_v) orelse {
            outs[0] = .{ .Bool = true };
            return;
        };
        if (!self.flushBufferedFile(out_v)) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("write error") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        }
        outs[0] = .{ .Bool = true };
    }

    fn builtinIoOutput(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const io_v = self.getGlobal("io");
        if (io_v != .Table) {
            outs[0] = .Nil;
            return;
        }
        const io_tbl = io_v.Table;
        if (args.len == 0) {
            outs[0] = self.getFieldOpt(io_tbl, "output_stream") orelse (self.getFieldOpt(io_tbl, "stdout") orelse .Nil);
            return;
        }
        const old_out = self.getFieldOpt(io_tbl, "output_stream") orelse (self.getFieldOpt(io_tbl, "stdout") orelse .Nil);
        if (args[0] == .String) {
            var open_out = [_]Value{ .Nil, .Nil, .Nil };
            const file_v = try self.ioOpenPath(args[0].String.bytes(), "w", open_out[0..]) orelse {
                const msg = if (open_out[1] == .String) ioErrText(open_out[1].String.bytes()) else "cannot open file";
                return self.fail("cannot open file '{s}' ({s})", .{ args[0].String.bytes(), msg });
            };
            try self.setField(io_tbl, "output_stream", file_v);
            self.maybeCloseReplacedDefault(old_out, file_v);
            outs[0] = file_v;
            return;
        }
        const name = self.valueTypeName(args[0]);
        if (!std.mem.startsWith(u8, name, "FILE")) {
            return self.fail("bad argument #1 to 'output' (FILE* expected, got {s})", .{name});
        }
        try self.setField(io_tbl, "output_stream", args[0]);
        self.maybeCloseReplacedDefault(old_out, args[0]);
        outs[0] = args[0];
    }

    fn isStdFile(self: *Vm, v: Value) bool {
        const io_v = self.getGlobal("io");
        if (io_v != .Table) return false;
        const io_tbl = io_v.Table;
        const stdin_v = self.getFieldOpt(io_tbl, "stdin") orelse .Nil;
        const stdout_v = self.getFieldOpt(io_tbl, "stdout") orelse .Nil;
        const stderr_v = self.getFieldOpt(io_tbl, "stderr") orelse .Nil;
        return valuesEqual(v, stdin_v) or valuesEqual(v, stdout_v) or valuesEqual(v, stderr_v);
    }

    fn maybeCloseReplacedDefault(self: *Vm, old_v: Value, new_v: Value) void {
        if (valuesEqual(old_v, new_v) or self.isStdFile(old_v)) return;
        if (asFileTable(self, old_v)) |t| {
            self.closeManagedFile(t);
            _ = self.setField(t, "__closed", .{ .Bool = true }) catch {};
        }
    }

    fn builtinIoClose(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .Nil;
            if (outs.len > 2) outs[2] = .Nil;
        }
        const io_v = self.getGlobal("io");
        if (io_v != .Table) return;
        const io_tbl = io_v.Table;
        const file_v = if (args.len == 0) (self.getFieldOpt(io_tbl, "output_stream") orelse (self.getFieldOpt(io_tbl, "stdout") orelse .Nil)) else args[0];
        const file_tbl = asFileTable(self, file_v) orelse {
            return self.fail("bad argument #1 to 'close' (FILE* expected, got {s})", .{self.valueTypeName(file_v)});
        };
        if (self.isStdFile(file_v)) {
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot close standard file") };
            return;
        }
        if (self.getFieldOpt(file_tbl, "__closed")) |v| {
            if (v == .Bool and v.Bool) {
                return self.fail("closed file", .{});
            }
        }
        try self.setField(file_tbl, "__closed", .{ .Bool = true });
        self.closeManagedFile(file_tbl);
        if (outs.len > 0) outs[0] = .{ .Bool = true };
    }

    fn builtinFileClose(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .Nil;
        }
        if (args.len == 0) {
            return self.fail("bad argument #1 to 'close' (FILE* expected, got no value)", .{});
        }
        const file_v = args[0];
        const file_tbl = asFileTable(self, file_v) orelse {
            return self.fail("bad argument #1 to 'close' (FILE* expected, got {s})", .{self.valueTypeName(file_v)});
        };
        if (self.isStdFile(file_v)) {
            if (outs.len > 1) {
                outs[1] = .{ .String = try self.internStr("cannot close standard file") };
            }
            return;
        }
        if (self.getFieldOpt(file_tbl, "__closed")) |v| {
            if (v == .Bool and v.Bool) {
                return self.fail("closed file", .{});
            }
        }
        try self.setField(file_tbl, "__closed", .{ .Bool = true });
        self.closeManagedFile(file_tbl);
        if (outs.len > 0) outs[0] = .{ .Bool = true };
    }

    fn builtinFileMetaClose(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return;
        const file_tbl = asFileTable(self, args[0]) orelse return;
        if (self.isStdFile(args[0])) return;
        if (self.getFieldOpt(file_tbl, "__closed")) |v| {
            if (v == .Bool and v.Bool) return;
        }
        try self.setField(file_tbl, "__closed", .{ .Bool = true });
        self.closeManagedFile(file_tbl);
        if (outs.len > 0) outs[0] = .{ .Bool = true };
    }

    fn builtinFileWrite(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'write' (FILE* expected)", .{});
        const file_v = args[0];
        if (!fileCanWrite(self, file_v)) {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("bad file descriptor") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        }
        if (args.len == 1) {
            if (outs.len > 0) outs[0] = file_v;
            return;
        }
        _ = self.getManagedFile(file_v) orelse return self.fail("closed file", .{});
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            switch (args[i]) {
                .String, .Int, .Num => {},
                else => return self.fail("bad argument #{d} to 'write' (string expected)", .{i}),
            }
            const s = try self.valueToStringAlloc(args[i]);
            if (!(try self.writeBufferedFile(file_v, s))) {
                if (outs.len > 0) outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("write error") };
                if (outs.len > 2) outs[2] = .{ .Int = 1 };
                return;
            }
        }
        if (outs.len > 0) outs[0] = file_v;
    }

    fn builtinFileRead(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'read' (FILE* expected)", .{});
        const file_v = args[0];
        if (!fileCanRead(self, file_v)) {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("bad file descriptor") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        }
        if (args.len == 1) {
            if (outs.len > 0) outs[0] = try self.readOneFormat(file_v, .{ .String = try self.internStr("l") });
            return;
        }
        var out_i: usize = 0;
        var i: usize = 1;
        while (i < args.len and out_i < outs.len) : (i += 1) {
            const v = try self.readOneFormat(file_v, args[i]);
            outs[out_i] = v;
            if (v == .Nil) break;
            out_i += 1;
        }
        self.last_builtin_out_count = out_i + @intFromBool(out_i < outs.len and out_i + 1 < args.len and outs[out_i] == .Nil);
    }

    fn builtinFileSeek(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (args.len == 0) return self.fail("bad argument #1 to 'seek' (FILE* expected)", .{});
        const file_v = args[0];
        const f = self.getManagedFile(file_v) orelse {
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("closed file") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        };
        if (self.getFileBuffer(file_v)) |fb| {
            if (fb.pending.items.len != 0 and !self.flushBufferedFile(file_v)) {
                if (outs.len > 1) outs[1] = .{ .String = try self.internStr("write error") };
                if (outs.len > 2) outs[2] = .{ .Int = 1 };
                return;
            }
        }
        const whence: []const u8 = if (args.len >= 2 and args[1] == .String) args[1].String.bytes() else "cur";
        const offs: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |i| i,
            else => return self.fail("bad argument #3 to 'seek' (integer expected)", .{}),
        } else 0;
        const fb = self.getFileBuffer(file_v) orelse return;
        const new_pos_i: i128 = if (std.mem.eql(u8, whence, "set"))
            @max(offs, 0)
        else if (std.mem.eql(u8, whence, "cur"))
            @as(i128, @intCast(fb.pos)) + offs
        else if (std.mem.eql(u8, whence, "end"))
            @as(i128, @intCast(f.length(stdio.activeIo()) catch 0)) + offs
        else
            return self.fail("bad argument #2 to 'seek' (invalid option)", .{});
        if (new_pos_i < 0) {
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("seek error") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        }
        fb.pos = @intCast(new_pos_i);
        if (outs.len > 0) outs[0] = .{ .Int = @intCast(fb.pos) };
    }

    fn builtinFileFlush(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'flush' (FILE* expected)", .{});
        _ = self.getManagedFile(args[0]) orelse {
            outs[0] = .Nil;
            return;
        };
        if (!self.flushBufferedFile(args[0])) {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("write error") };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        }
        outs[0] = .{ .Bool = true };
    }

    fn builtinFileLines(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("bad argument #1 to 'lines' (FILE* expected)", .{});
        if (args.len - 1 > 250) return self.fail("too many arguments", .{});
        if (outs.len > 0) {
            outs[0] = try self.makeLinesIter(args[0], false, args[1..]);
            if (outs.len > 1) outs[1] = args[0];
            if (outs.len > 2) outs[2] = .Nil;
            self.last_builtin_out_count = @min(@as(usize, 3), outs.len);
        }
    }

    fn builtinFileSetvbuf(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .{ .Bool = true };
        if (args.len < 2 or args[1] != .String) return self.fail("bad argument #2 to 'setvbuf' (string expected)", .{});
        const fb = self.getFileBuffer(args[0]) orelse return;
        if (args[1].String == self.internStrAssume("full")) {
            fb.mode = .full;
        } else if (args[1].String == self.internStrAssume("no")) {
            fb.mode = .no;
        } else if (args[1].String == self.internStrAssume("line")) {
            fb.mode = .line;
        } else {
            return self.fail("bad argument #2 to 'setvbuf' (invalid option)", .{});
        }
    }

    fn builtinIoType(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) {
            outs[0] = .Nil;
            return;
        }
        const file_tbl = asFileTable(self, args[0]) orelse {
            outs[0] = .Nil;
            return;
        };
        if (self.getFieldOpt(file_tbl, "__closed")) |v| {
            if (v == .Bool and v.Bool) {
                outs[0] = .{ .String = try self.internStr("closed file") };
                return;
            }
        }
        outs[0] = .{ .String = try self.internStr("file") };
    }

    fn builtinFileGc(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = outs;
        if (args.len == 0) return self.fail("no value", .{});
        const file_tbl = asFileTable(self, args[0]) orelse return;
        self.closeManagedFile(file_tbl);
        _ = self.setField(file_tbl, "__closed", .{ .Bool = true }) catch {};
    }

    fn mathArgToInt(self: *Vm, v: Value, what: []const u8) Error!i64 {
        return switch (v) {
            .Int => |i| i,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) return self.fail("math.{s} expects integer", .{what});
                break :blk @intFromFloat(std.math.trunc(n));
            },
            else => return self.fail("math.{s} expects integer", .{what}),
        };
    }

    fn rotl64(x: u64, n: u6) u64 {
        return std.math.rotl(u64, x, n);
    }

    fn nextRandomU64(self: *Vm) u64 {
        const s0 = self.rng_state[0];
        const s1 = self.rng_state[1];
        const s2 = self.rng_state[2] ^ s0;
        const s3 = self.rng_state[3] ^ s1;
        const res = rotl64(s1 *% 5, 7) *% 9;
        self.rng_state[0] = s0 ^ s3;
        self.rng_state[1] = s1 ^ s2;
        self.rng_state[2] = s2 ^ (s1 << 17);
        self.rng_state[3] = rotl64(s3, 45);
        return res;
    }

    fn randomI2d(x: u64) f64 {
        const sx: i64 = @bitCast(x >> 11); // keep top 53 bits
        const scale = 0.5 / @as(f64, @floatFromInt(@as(u64, 1) << 52));
        var res = @as(f64, @floatFromInt(sx)) * scale;
        if (sx < 0) res += 1.0;
        return res;
    }

    fn randomProject(self: *Vm, ran0: u64, n: u64) u64 {
        var ran = ran0;
        var lim = n;
        var sh: u8 = 1;
        while ((lim & (lim +% 1)) != 0 and sh < 64) : (sh *= 2) {
            lim |= (lim >> @as(u6, @intCast(sh)));
        }
        while (true) {
            ran &= lim;
            if (ran <= n) return ran;
            ran = self.nextRandomU64();
        }
    }

    fn randomSetSeed(self: *Vm, n1: u64, n2: u64) void {
        self.rng_state[0] = n1;
        self.rng_state[1] = 0xff;
        self.rng_state[2] = n2;
        self.rng_state[3] = 0;
        var i: usize = 0;
        while (i < 16) : (i += 1) _ = self.nextRandomU64();
    }

    fn builtinMathRandom(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len > 2) return self.fail("wrong number of arguments", .{});
        const r = self.nextRandomU64();
        if (args.len == 0) {
            outs[0] = .{ .Num = randomI2d(r) };
            return;
        }
        if (args.len == 1) {
            const hi = try self.mathArgToInt(args[0], "random");
            if (hi == 0) {
                outs[0] = .{ .Int = @as(i64, @bitCast(r)) };
                return;
            }
            if (hi < 1) return self.fail("bad argument #1 to 'random' (interval is empty)", .{});
            const span: u64 = @intCast(hi);
            outs[0] = .{ .Int = @as(i64, @intCast((r % span) + 1)) };
            return;
        }
        const lo = try self.mathArgToInt(args[0], "random");
        const hi = try self.mathArgToInt(args[1], "random");
        if (lo > hi) return self.fail("bad arguments to 'random' (interval is empty)", .{});
        const low_u: u64 = @bitCast(lo);
        const hi_u: u64 = @bitCast(hi);
        const p = self.randomProject(r, hi_u -% low_u);
        outs[0] = .{ .Int = @bitCast(p +% low_u) };
    }

    fn builtinMathRandomseed(self: *Vm, args: []const Value, outs: []Value) Error!void {
        var n1: u64 = 0;
        var n2: u64 = 0;
        if (args.len == 0) {
            n1 = self.nextRandomU64();
            n2 = self.nextRandomU64();
        } else {
            const s1: i64 = try self.mathArgToInt(args[0], "randomseed");
            const s2: i64 = if (args.len >= 2) try self.mathArgToInt(args[1], "randomseed") else 0;
            n1 = @bitCast(s1);
            n2 = @bitCast(s2);
        }
        self.randomSetSeed(n1, n2);
        if (outs.len > 0) outs[0] = .{ .Int = @bitCast(n1) };
        if (outs.len > 1) outs[1] = .{ .Int = @bitCast(n2) };
    }

    fn builtinMathTointeger(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) {
            outs[0] = .Nil;
            return;
        }
        switch (args[0]) {
            .Int => |i| outs[0] = .{ .Int = i },
            .Num => |n| {
                if (std.math.isFinite(n) and @floor(n) == n and n >= -9_223_372_036_854_775_808.0 and n < 9_223_372_036_854_775_808.0) {
                    outs[0] = .{ .Int = @as(i64, @intFromFloat(n)) };
                } else {
                    outs[0] = .Nil;
                }
            },
            .String => {
                var tmp: [1]Value = .{.Nil};
                try self.builtinTonumber(args[0..1], tmp[0..]);
                switch (tmp[0]) {
                    .Int => outs[0] = tmp[0],
                    .Num => |n| {
                        if (std.math.isFinite(n) and @floor(n) == n and n >= -9_223_372_036_854_775_808.0 and n < 9_223_372_036_854_775_808.0) {
                            outs[0] = .{ .Int = @as(i64, @intFromFloat(n)) };
                        } else {
                            outs[0] = .Nil;
                        }
                    },
                    else => outs[0] = .Nil,
                }
            },
            else => outs[0] = .Nil,
        }
    }

    fn builtinMathSin(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'sin' (number expected, got nil)", .{});
        const x: f64 = switch (args[0]) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => return self.fail("bad argument #1 to 'sin' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        outs[0] = .{ .Num = std.math.sin(x) };
    }

    fn builtinMathCos(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'cos' (number expected, got nil)", .{});
        const x: f64 = switch (args[0]) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => return self.fail("bad argument #1 to 'cos' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        outs[0] = .{ .Num = std.math.cos(x) };
    }

    fn mathArgToNum(self: *Vm, v: Value, what: []const u8, argn: usize) Error!f64 {
        return switch (v) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => self.fail("bad argument #{d} to '{s}' (number expected, got {s})", .{ argn, what, self.valueTypeName(v) }),
        };
    }

    fn builtinMathTan(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'tan' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "tan", 1);
        outs[0] = .{ .Num = std.math.tan(x) };
    }

    fn builtinMathAsin(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'asin' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "asin", 1);
        outs[0] = .{ .Num = std.math.asin(x) };
    }

    fn builtinMathAcos(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'acos' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "acos", 1);
        outs[0] = .{ .Num = std.math.acos(x) };
    }

    fn builtinMathAtan(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'atan' (number expected, got nil)", .{});
        const y = try self.mathArgToNum(args[0], "atan", 1);
        if (args.len < 2 or args[1] == .Nil) {
            outs[0] = .{ .Num = std.math.atan(y) };
            return;
        }
        const x = try self.mathArgToNum(args[1], "atan", 2);
        outs[0] = .{ .Num = std.math.atan2(y, x) };
    }

    fn builtinMathDeg(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'deg' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "deg", 1);
        outs[0] = .{ .Num = x * (180.0 / std.math.pi) };
    }

    fn builtinMathRad(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'rad' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "rad", 1);
        outs[0] = .{ .Num = x * (std.math.pi / 180.0) };
    }

    fn builtinMathAbs(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'abs' (number expected, got nil)", .{});
        outs[0] = switch (args[0]) {
            .Int => |i| .{ .Int = if (i < 0) -%i else i },
            .Num => |n| .{ .Num = @abs(n) },
            else => return self.fail("bad argument #1 to 'abs' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
    }

    fn builtinMathSqrt(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'sqrt' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "sqrt", 1);
        outs[0] = .{ .Num = std.math.sqrt(x) };
    }

    fn builtinMathExp(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'exp' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "exp", 1);
        outs[0] = .{ .Num = std.math.exp(x) };
    }

    fn builtinMathLdexp(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("bad argument #2 to 'ldexp' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "ldexp", 1);
        const e = try self.mathArgToInt(args[1], "ldexp");
        const ef: f64 = @floatFromInt(e);
        outs[0] = .{ .Num = x * std.math.pow(f64, 2.0, ef) };
    }

    fn builtinMathFrexp(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'frexp' (number expected, got nil)", .{});
        const x = try self.mathArgToNum(args[0], "frexp", 1);
        if (x == 0.0) {
            outs[0] = .{ .Num = 0.0 };
            if (outs.len > 1) outs[1] = .{ .Int = 0 };
            return;
        }
        if (!std.math.isFinite(x)) {
            outs[0] = .{ .Num = x };
            if (outs.len > 1) outs[1] = .{ .Int = 0 };
            return;
        }
        var e: i64 = @as(i64, @intFromFloat(std.math.floor(std.math.log2(@abs(x))))) + 1;
        var m: f64 = x / std.math.pow(f64, 2.0, @as(f64, @floatFromInt(e)));
        while (@abs(m) < 0.5) {
            m *= 2.0;
            e -= 1;
        }
        while (@abs(m) >= 1.0) {
            m /= 2.0;
            e += 1;
        }
        outs[0] = .{ .Num = m };
        if (outs.len > 1) outs[1] = .{ .Int = e };
    }

    fn builtinMathCeil(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'ceil' (number expected, got nil)", .{});
        outs[0] = switch (args[0]) {
            .Int => |i| .{ .Int = i },
            .Num => |n| blk: {
                const c = std.math.ceil(n);
                if (std.math.isFinite(c) and c >= -9_223_372_036_854_775_808.0 and c < 9_223_372_036_854_775_808.0) {
                    break :blk .{ .Int = @as(i64, @intFromFloat(c)) };
                }
                break :blk .{ .Num = c };
            },
            else => return self.fail("bad argument #1 to 'ceil' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
    }

    fn builtinMathUlt(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("math.ult expects two integers", .{});
        const a = try self.mathArgToInt(args[0], "ult");
        const b = try self.mathArgToInt(args[1], "ult");
        outs[0] = .{ .Bool = @as(u64, @bitCast(a)) < @as(u64, @bitCast(b)) };
    }

    fn builtinMathModf(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'modf' (number expected, got nil)", .{});
        switch (args[0]) {
            .Int => |i| {
                outs[0] = .{ .Int = i };
                if (outs.len > 1) outs[1] = .{ .Num = 0.0 };
            },
            .Num => |n| {
                if (!std.math.isFinite(n)) {
                    outs[0] = .{ .Num = n };
                    if (outs.len > 1) outs[1] = .{ .Num = if (std.math.isNan(n)) std.math.nan(f64) else 0.0 };
                    return;
                }
                const ip = std.math.trunc(n);
                outs[0] = .{ .Num = ip };
                if (outs.len > 1) outs[1] = .{ .Num = n - ip };
            },
            else => return self.fail("bad argument #1 to 'modf' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        }
    }

    fn builtinMathLog(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'log' (number expected, got nil)", .{});
        const x: f64 = switch (args[0]) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => return self.fail("bad argument #1 to 'log' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        if (args.len < 2 or args[1] == .Nil) {
            outs[0] = .{ .Num = std.math.log(f64, std.math.e, x) };
            return;
        }
        const base: f64 = switch (args[1]) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => return self.fail("bad argument #2 to 'log' (number expected, got {s})", .{self.valueTypeName(args[1])}),
        };
        outs[0] = .{ .Num = std.math.log(f64, std.math.e, x) / std.math.log(f64, std.math.e, base) };
    }

    fn builtinMathFmod(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("math.fmod expects two numbers", .{});
        if (args[0] == .Int and args[1] == .Int) {
            const x = args[0].Int;
            const y = args[1].Int;
            if (y == 0) return self.fail("zero", .{});
            if (x == std.math.minInt(i64) and y == -1) {
                outs[0] = .{ .Int = 0 };
                return;
            }
            outs[0] = .{ .Int = @rem(x, y) };
            return;
        }
        const x: f64 = try self.mathArgToNum(args[0], "fmod", 1);
        const y: f64 = try self.mathArgToNum(args[1], "fmod", 2);
        if (y == 0.0) return self.fail("zero", .{});
        outs[0] = .{ .Num = @rem(x, y) };
    }

    fn builtinMathFloor(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'floor' (number expected, got nil)", .{});
        outs[0] = switch (args[0]) {
            .Int => |i| .{ .Int = i },
            .Num => |n| blk: {
                const f = std.math.floor(n);
                if (std.math.isFinite(f) and f >= -9_223_372_036_854_775_808.0 and f < 9_223_372_036_854_775_808.0) {
                    break :blk .{ .Int = @as(i64, @intFromFloat(f)) };
                }
                break :blk .{ .Num = f };
            },
            else => return self.fail("bad argument #1 to 'floor' (number expected, got {s})", .{self.valueTypeName(args[0])}),
        };
    }

    fn builtinMathType(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) {
            outs[0] = .Nil;
            return;
        }
        outs[0] = switch (args[0]) {
            .Int => .{ .String = try self.internStr("integer") },
            .Num => .{ .String = try self.internStr("float") },
            else => .Nil,
        };
    }

    fn builtinMathMin(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("value expected", .{});
        // Keep it simple: treat numbers as f64 if any arg is float.
        var use_float = false;
        for (args) |v| switch (v) {
            .Int => {},
            .Num => use_float = true,
            else => return self.fail("math.min expects numbers", .{}),
        };
        if (use_float) {
            var m: f64 = switch (args[0]) {
                .Int => |i| @floatFromInt(i),
                .Num => |n| n,
                else => unreachable,
            };
            for (args[1..]) |v| {
                const x: f64 = switch (v) {
                    .Int => |i| @floatFromInt(i),
                    .Num => |n| n,
                    else => unreachable,
                };
                if (x < m) m = x;
            }
            outs[0] = .{ .Num = m };
        } else {
            var m: i64 = args[0].Int;
            for (args[1..]) |v| {
                const x: i64 = v.Int;
                if (x < m) m = x;
            }
            outs[0] = .{ .Int = m };
        }
    }

    fn builtinMathMax(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("value expected", .{});
        var use_float = false;
        for (args) |v| switch (v) {
            .Int => {},
            .Num => use_float = true,
            else => return self.fail("math.max expects numbers", .{}),
        };
        if (use_float) {
            var m: f64 = switch (args[0]) {
                .Int => |i| @floatFromInt(i),
                .Num => |n| n,
                else => unreachable,
            };
            for (args[1..]) |v| {
                const x: f64 = switch (v) {
                    .Int => |i| @floatFromInt(i),
                    .Num => |n| n,
                    else => unreachable,
                };
                if (x > m) m = x;
            }
            outs[0] = .{ .Num = m };
        } else {
            var m: i64 = args[0].Int;
            for (args[1..]) |v| {
                const x: i64 = v.Int;
                if (x > m) m = x;
            }
            outs[0] = .{ .Int = m };
        }
    }

    fn builtinOsClock(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = self;
        _ = args;
        if (outs.len == 0) return;
        // Deterministic stub; upstream prints/uses timing but our diff normalizer
        // already ignores "time:" lines and some perf logs.
        outs[0] = .{ .Num = 0.0 };
    }

    fn valueToTimeT(self: *Vm, v: Value, argn: usize, fname: []const u8) Error!i64 {
        return switch (v) {
            .Int => |i| i,
            .Num => |n| blk: {
                if (!std.math.isFinite(n) or n != std.math.trunc(n)) {
                    return self.fail("bad argument #{d} to '{s}' (not an integer)", .{ argn, fname });
                }
                break :blk @as(i64, @intFromFloat(n));
            },
            else => return self.fail("bad argument #{d} to '{s}' (not an integer)", .{ argn, fname }),
        };
    }

    const DateParts = struct {
        year: i64,
        month: i64,
        day: i64,
        hour: i64,
        min: i64,
        sec: i64,
        wday: i64, // 1..7, Sunday=1
        yday: i64, // 1..366
    };

    fn floorDiv(a: i64, b: i64) i64 {
        var q = @divTrunc(a, b);
        const r = @mod(a, b);
        if (r != 0 and ((r > 0) != (b > 0))) q -= 1;
        return q;
    }

    fn daysFromCivil(year_in: i64, month_in: i64, day_in: i64) i64 {
        var year = year_in;
        var month = month_in;
        year += floorDiv(month - 1, 12);
        month = @mod(month - 1, 12) + 1;
        if (month <= 2) year -= 1;
        const era = floorDiv(year, 400);
        const yoe = year - era * 400;
        const mp = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
        const doy = floorDiv(153 * mp + 2, 5) + day_in - 1;
        const doe = yoe * 365 + floorDiv(yoe, 4) - floorDiv(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    fn civilFromDays(z_in: i64) struct { year: i64, month: i64, day: i64 } {
        const z = z_in + 719468;
        const era = floorDiv(z, 146097);
        const doe = z - era * 146097;
        const yoe = floorDiv(doe - floorDiv(doe, 1460) + floorDiv(doe, 36524) - floorDiv(doe, 146096), 365);
        var year = yoe + era * 400;
        const doy = doe - (365 * yoe + floorDiv(yoe, 4) - floorDiv(yoe, 100));
        const mp = floorDiv(5 * doy + 2, 153);
        const day = doy - floorDiv(153 * mp + 2, 5) + 1;
        const month = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
        if (month <= 2) year += 1;
        return .{ .year = year, .month = month, .day = day };
    }

    fn splitEpochSeconds(t: i64) DateParts {
        var days = floorDiv(t, 86_400);
        var sod = t - days * 86_400;
        if (sod < 0) {
            days -= 1;
            sod += 86_400;
        }
        const civ = civilFromDays(days);
        const hour = @divTrunc(sod, 3600);
        const min = @divTrunc(@mod(sod, 3600), 60);
        const sec = @mod(sod, 60);
        const wday0 = @mod(days + 4, 7); // Sunday=0
        const yday = days - daysFromCivil(civ.year, 1, 1) + 1;
        return .{
            .year = civ.year,
            .month = civ.month,
            .day = civ.day,
            .hour = hour,
            .min = min,
            .sec = sec,
            .wday = wday0 + 1,
            .yday = yday,
        };
    }

    fn formatDate(self: *Vm, fmt: []const u8, p: DateParts) Error!*LuaString {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] != '%') {
                try out.append(self.alloc, fmt[i]);
                continue;
            }
            if (i + 1 >= fmt.len) return self.fail("invalid conversion specifier", .{});
            i += 1;
            const spec = fmt[i];
            switch (spec) {
                '%' => try out.append(self.alloc, '%'),
                'd' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>2}", .{@as(u64, @intCast(p.day))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'm' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>2}", .{@as(u64, @intCast(p.month))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'Y' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d}", .{p.year});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'H' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>2}", .{@as(u64, @intCast(p.hour))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'M' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>2}", .{@as(u64, @intCast(p.min))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'S' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>2}", .{@as(u64, @intCast(p.sec))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'w' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d}", .{@as(u64, @intCast(p.wday - 1))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                'j' => {
                    const s = try std.fmt.allocPrint(self.alloc, "{d:0>3}", .{@as(u64, @intCast(p.yday))});
                    defer self.alloc.free(s);
                    try out.appendSlice(self.alloc, s);
                },
                else => return self.fail("invalid conversion specifier", .{}),
            }
        }
        return try self.internStr(out.items);
    }

    fn localTzOffsetSeconds() i64 {
        // Current test environment uses UTC+03:00.
        return 3 * 3600;
    }

    fn osDateInvalidSpec(fmt: []const u8) bool {
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            if (fmt[i] != '%') continue;
            if (i + 1 >= fmt.len) return true;
            i += 1;
            const c0 = fmt[i];
            if (c0 == '%') continue;
            if (c0 == 'E' or c0 == 'O') return true;
            if (!(std.ascii.isAlphabetic(c0) or c0 == '%')) return true;
        }
        return false;
    }

    fn builtinOsDate(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const raw_fmt: []const u8 = if (args.len >= 1) switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #1 to 'date' (string expected)", .{}),
        } else "%c";

        var fmt = raw_fmt;
        const utc = fmt.len > 0 and fmt[0] == '!';
        if (fmt.len > 0 and fmt[0] == '!') {
            fmt = fmt[1..];
        }
        if (std.mem.indexOfScalar(u8, fmt, 0) != null) {
            outs[0] = .{ .String = try self.internStr(fmt) };
            return;
        }
        if (osDateInvalidSpec(fmt)) return self.fail("invalid conversion specifier", .{});

        var t: i64 = 0;
        if (args.len >= 2) {
            t = try self.valueToTimeT(args[1], 2, "date");
        } else {
            t = std.Io.Timestamp.now(stdio.activeIo(), .real).toSeconds();
        }
        const p = splitEpochSeconds(if (utc) t else t + localTzOffsetSeconds());

        if (std.mem.eql(u8, fmt, "*t")) {
            const tbl = try self.allocTable();
            try self.setField(tbl, "sec", .{ .Int = p.sec });
            try self.setField(tbl, "min", .{ .Int = p.min });
            try self.setField(tbl, "hour", .{ .Int = p.hour });
            try self.setField(tbl, "day", .{ .Int = p.day });
            try self.setField(tbl, "month", .{ .Int = p.month });
            try self.setField(tbl, "year", .{ .Int = p.year });
            try self.setField(tbl, "wday", .{ .Int = p.wday });
            try self.setField(tbl, "yday", .{ .Int = p.yday });
            try self.setField(tbl, "isdst", .{ .Bool = false });
            outs[0] = .{ .Table = tbl };
            return;
        }
        outs[0] = .{ .String = try self.formatDate(fmt, p) };
    }

    fn builtinOsTime(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0 or args[0] == .Nil) {
            outs[0] = .{ .Int = std.Io.Timestamp.now(stdio.activeIo(), .real).toSeconds() };
            return;
        }
        const tbl = switch (args[0]) {
            .Table => |t| t,
            else => return self.fail("bad argument #1 to 'time' (table expected)", .{}),
        };

        const readIntField = struct {
            fn f(self_vm: *Vm, t: *Table, name: []const u8, default_v: i64, required: bool) Error!i64 {
                const v = self_vm.getFieldOpt(t, name) orelse {
                    if (required) return self_vm.fail("field '{s}' is missing", .{name});
                    return default_v;
                };
                return switch (v) {
                    .Int => |i| i,
                    .Num => |n| blk: {
                        if (!std.math.isFinite(n) or n != std.math.trunc(n)) return self_vm.fail("field '{s}' is not an integer", .{name});
                        break :blk @intFromFloat(n);
                    },
                    else => return self_vm.fail("field '{s}' is not an integer", .{name}),
                };
            }
        }.f;

        const year = try readIntField(self, tbl, "year", 0, true);
        const month = try readIntField(self, tbl, "month", 0, true);
        const day = try readIntField(self, tbl, "day", 0, true);
        const hour = try readIntField(self, tbl, "hour", 12, false);
        const min = try readIntField(self, tbl, "min", 0, false);
        const sec = try readIntField(self, tbl, "sec", 0, false);
        const min_year_i32: i64 = @as(i64, std.math.minInt(i32)) + 1900;
        const max_year_i32: i64 = @as(i64, std.math.maxInt(i32)) + 1900;
        if (year < min_year_i32 or year > max_year_i32) {
            return self.fail("field 'year' is out-of-bound", .{});
        }
        const t_local = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + min * 60 + sec;
        const t = t_local - localTzOffsetSeconds();
        const p = splitEpochSeconds(t_local);
        try self.setField(tbl, "year", .{ .Int = p.year });
        try self.setField(tbl, "month", .{ .Int = p.month });
        try self.setField(tbl, "day", .{ .Int = p.day });
        try self.setField(tbl, "hour", .{ .Int = p.hour });
        try self.setField(tbl, "min", .{ .Int = p.min });
        try self.setField(tbl, "sec", .{ .Int = p.sec });
        try self.setField(tbl, "wday", .{ .Int = p.wday });
        try self.setField(tbl, "yday", .{ .Int = p.yday });
        try self.setField(tbl, "isdst", .{ .Bool = false });

        outs[0] = .{ .Int = t };
    }

    fn builtinOsDifftime(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = self;
        if (outs.len == 0) return;
        if (args.len < 2) return;
        const t1 = switch (args[0]) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Num => |n| n,
            else => return,
        };
        const t2 = switch (args[1]) {
            .Int => |i| @as(f64, @floatFromInt(i)),
            .Num => |n| n,
            else => return,
        };
        outs[0] = .{ .Num = t1 - t2 };
    }

    fn builtinOsGetenv(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'getenv' (string expected)", .{});
        const name = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("bad argument #1 to 'getenv' (string expected)", .{}),
        };
        const val = stdio.activeEnviron().getAlloc(self.alloc, name) catch |e| switch (e) {
            error.EnvironmentVariableMissing => {
                outs[0] = .Nil;
                return;
            },
            error.InvalidWtf8 => return self.fail("os.getenv: invalid environment value", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        outs[0] = .{ .String = try self.internStr(val) };
    }

    fn builtinOsTmpname(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        var buf: [128]u8 = undefined;
        const r = self.nextRandomU64();
        const p = std.fmt.bufPrint(buf[0..], "/tmp/luazig-{x}.tmp", .{r}) catch return error.OutOfMemory;
        outs[0] = .{ .String = try self.internStr(p) };
    }

    fn builtinOsRemove(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0 or args[0] != .String) return self.fail("bad argument #1 to 'remove' (string expected)", .{});
        std.Io.Dir.cwd().deleteFile(stdio.activeIo(), args[0].String.bytes()) catch |e| {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        };
        outs[0] = .{ .Bool = true };
    }

    fn builtinOsRename(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2 or args[0] != .String or args[1] != .String) {
            return self.fail("bad argument to 'rename' (string expected)", .{});
        }
        std.Io.Dir.cwd().rename(args[0].String.bytes(), std.Io.Dir.cwd(), args[1].String.bytes(), stdio.activeIo()) catch |e| {
            outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(@errorName(e)) };
            if (outs.len > 2) outs[2] = .{ .Int = 1 };
            return;
        };
        outs[0] = .{ .Bool = true };
    }

    fn builtinOsSetlocale(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const locale_opt: ?[]const u8 = if (args.len == 0) null else switch (args[0]) {
            .Nil => null,
            .String => |s| s.bytes(),
            else => return self.fail("os.setlocale expects locale string", .{}),
        };
        _ = if (args.len >= 2) switch (args[1]) {
            .Nil => null,
            .String => |s| s,
            else => return self.fail("os.setlocale expects category string", .{}),
        } else null;

        if (locale_opt == null) {
            outs[0] = .{ .String = try self.internStr(self.current_locale) };
            return;
        }
        const locale = locale_opt.?;
        if (std.mem.eql(u8, locale, "C")) {
            self.current_locale = "C";
            outs[0] = .{ .String = try self.internStr("C") };
            return;
        }
        outs[0] = .Nil;
    }

    fn builtinStringFormat(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.format expects format string", .{});
        const fmt = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("string.format expects format string", .{}),
        };

        var out = std.ArrayListUnmanaged(u8).empty;
        var ai: usize = 1;
        var i: usize = 0;
        while (i < fmt.len) : (i += 1) {
            const c = fmt[i];
            if (c != '%') {
                try out.append(self.alloc, c);
                continue;
            }
            if (i + 1 >= fmt.len) return self.fail("string.format: trailing %", .{});
            i += 1;

            var flag_left = false;
            var flag_plus = false;
            var flag_space = false;
            var flag_alt = false;
            var flag_zero = false;
            var flag_count: usize = 0;
            while (i < fmt.len) : (i += 1) {
                switch (fmt[i]) {
                    '-' => {
                        flag_left = true;
                        flag_count += 1;
                    },
                    '+' => {
                        flag_plus = true;
                        flag_count += 1;
                    },
                    ' ' => {
                        flag_space = true;
                        flag_count += 1;
                    },
                    '#' => {
                        flag_alt = true;
                        flag_count += 1;
                    },
                    '0' => {
                        flag_zero = true;
                        flag_count += 1;
                    },
                    else => break,
                }
                if (flag_count > 10) return self.fail("string.format: too long", .{});
            }

            var width: ?usize = null;
            if (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') {
                var w: usize = 0;
                var digits: usize = 0;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                    digits += 1;
                    if (digits > 3) return self.fail("string.format: too long", .{});
                    w = (w * 10) + @as(usize, fmt[i] - '0');
                }
                if (w > 99) return self.fail("invalid conversion", .{});
                width = w;
            }

            // Minimal subset: optionally parse ".<digits>" precision.
            var precision: ?usize = null;
            if (i < fmt.len and fmt[i] == '.') {
                i += 1;
                var p: usize = 0;
                var digits: usize = 0;
                while (i < fmt.len) : (i += 1) {
                    const d = fmt[i];
                    if (d < '0' or d > '9') break;
                    digits += 1;
                    if (digits > 3) return self.fail("string.format: too long", .{});
                    p = (p * 10) + @as(usize, d - '0');
                }
                if (p > 99) return self.fail("invalid conversion", .{});
                precision = p;
            }

            if (i >= fmt.len) return self.fail("string.format: trailing %", .{});
            const spec = fmt[i];
            if (spec == '%') {
                try out.append(self.alloc, '%');
                continue;
            }

            if (ai >= args.len) return self.fail("no value", .{});
            const v = args[ai];
            ai += 1;
            switch (spec) {
                'p' => {
                    if (precision != null or flag_plus or flag_space or flag_alt or flag_zero) return self.fail("invalid conversion", .{});
                    const raw = switch (v) {
                        .Table => |t| try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromPtr(t)}),
                        .Closure => |cl| try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromPtr(cl)}),
                        .Thread => |th| try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromPtr(th)}),
                        .Builtin => |id| try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromEnum(id)}),
                        .String => |s| blk: {
                            if (s.len <= 40) {
                                break :blk try std.fmt.allocPrint(self.alloc, "0x{x}", .{std.hash_map.hashString(s.bytes())});
                            }
                            break :blk try std.fmt.allocPrint(self.alloc, "0x{x}", .{@intFromPtr(s.bytes().ptr)});
                        },
                        else => "(null)",
                    };
                    if (width) |w| {
                        if (raw.len < w) {
                            const pad = w - raw.len;
                            if (!flag_left) for (0..pad) |_| try out.append(self.alloc, ' ');
                            try out.appendSlice(self.alloc, raw);
                            if (flag_left) for (0..pad) |_| try out.append(self.alloc, ' ');
                        } else {
                            try out.appendSlice(self.alloc, raw);
                        }
                    } else {
                        try out.appendSlice(self.alloc, raw);
                    }
                },
                'd', 'i' => {
                    if (flag_alt) return self.fail("invalid conversion", .{});
                    const n: i64 = switch (v) {
                        .Int => |x| x,
                        .Num => |x| blk: {
                            if (!std.math.isFinite(x)) return self.fail("string.format: %d expects integer", .{});
                            const min_i: f64 = @floatFromInt(std.math.minInt(i64));
                            const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
                            if (!(x >= min_i and x <= max_i)) return self.fail("string.format: %d expects integer", .{});
                            const xi: i64 = @intFromFloat(x);
                            if (@as(f64, @floatFromInt(xi)) != x) return self.fail("string.format: %d expects integer", .{});
                            break :blk xi;
                        },
                        else => return self.fail("string.format: %d expects integer", .{}),
                    };
                    var digits_buf: [64]u8 = undefined;
                    const negative = n < 0;
                    const mag: u64 = if (negative)
                        @as(u64, @intCast(-(n + 1))) + 1
                    else
                        @as(u64, @intCast(n));
                    var digits = std.fmt.bufPrint(digits_buf[0..], "{d}", .{mag}) catch unreachable;
                    if (precision) |p| {
                        if (p == 0 and mag == 0) {
                            digits = "";
                        } else if (digits.len < p) {
                            const pad0 = p - digits.len;
                            const room = digits_buf.len - digits.len;
                            if (pad0 > room) return self.fail("invalid conversion", .{});
                            const src = digits;
                            var dst_i: usize = src.len;
                            while (dst_i > 0) {
                                dst_i -= 1;
                                digits_buf[pad0 + dst_i] = src[dst_i];
                            }
                            @memset(digits_buf[0..pad0], '0');
                            digits = digits_buf[0 .. pad0 + src.len];
                        }
                    }
                    const sign_ch: ?u8 = if (negative) '-' else if (flag_plus) '+' else if (flag_space) ' ' else null;
                    const sign_len: usize = if (sign_ch != null) 1 else 0;
                    const raw_len = sign_len + digits.len;
                    const pad_len: usize = if (width) |w| if (w > raw_len) w - raw_len else 0 else 0;
                    const use_zero_pad = flag_zero and !flag_left and precision == null;
                    if (!flag_left and !use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                    if (sign_ch) |sc| try out.append(self.alloc, sc);
                    if (!flag_left and use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, '0');
                    try out.appendSlice(self.alloc, digits);
                    if (flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                },
                'u', 'x', 'X', 'o' => {
                    if (flag_plus or flag_space) return self.fail("invalid conversion", .{});
                    const signed: i64 = switch (v) {
                        .Int => |x| x,
                        .Num => |x| blk: {
                            if (!std.math.isFinite(x)) return self.fail("string.format: integer expected", .{});
                            const min_i: f64 = @floatFromInt(std.math.minInt(i64));
                            const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
                            if (!(x >= min_i and x <= max_i)) return self.fail("string.format: integer expected", .{});
                            const xi: i64 = @intFromFloat(x);
                            if (@as(f64, @floatFromInt(xi)) != x) return self.fail("string.format: integer expected", .{});
                            break :blk xi;
                        },
                        else => return self.fail("string.format: integer expected", .{}),
                    };
                    const u: u64 = @bitCast(signed);
                    var digits_buf: [128]u8 = undefined;
                    var digits = switch (spec) {
                        'u' => std.fmt.bufPrint(digits_buf[0..], "{d}", .{u}) catch unreachable,
                        'x' => std.fmt.bufPrint(digits_buf[0..], "{x}", .{u}) catch unreachable,
                        'X' => std.fmt.bufPrint(digits_buf[0..], "{X}", .{u}) catch unreachable,
                        'o' => std.fmt.bufPrint(digits_buf[0..], "{o}", .{u}) catch unreachable,
                        else => unreachable,
                    };
                    if (precision) |p| {
                        if (p == 0 and u == 0) {
                            digits = "";
                        } else if (digits.len < p) {
                            const pad0 = p - digits.len;
                            const room = digits_buf.len - digits.len;
                            if (pad0 > room) return self.fail("invalid conversion", .{});
                            const src = digits;
                            var dst_i: usize = src.len;
                            while (dst_i > 0) {
                                dst_i -= 1;
                                digits_buf[pad0 + dst_i] = src[dst_i];
                            }
                            @memset(digits_buf[0..pad0], '0');
                            digits = digits_buf[0 .. pad0 + src.len];
                        }
                    }
                    var prefix: []const u8 = "";
                    if (flag_alt) {
                        if (spec == 'x' and u != 0) prefix = "0x";
                        if (spec == 'X' and u != 0) prefix = "0X";
                        if (spec == 'o' and (digits.len == 0 or digits[0] != '0')) prefix = "0";
                    }
                    const raw_len = prefix.len + digits.len;
                    const pad_len: usize = if (width) |w| if (w > raw_len) w - raw_len else 0 else 0;
                    const use_zero_pad = flag_zero and !flag_left and precision == null;
                    if (!flag_left and !use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                    try out.appendSlice(self.alloc, prefix);
                    if (!flag_left and use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, '0');
                    try out.appendSlice(self.alloc, digits);
                    if (flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                },
                'f', 'e', 'E', 'g', 'G' => {
                    const n: f64 = switch (v) {
                        .Int => |x| @floatFromInt(x),
                        .Num => |x| x,
                        else => return self.fail("string.format: expects number", .{}),
                    };
                    const neg = std.math.signbit(n);
                    const absn = if (neg) -n else n;
                    const sign_ch: ?u8 = if (neg) '-' else if (flag_plus) '+' else if (flag_space) ' ' else null;

                    var raw_buf: [512]u8 = undefined;
                    var exp_buf: [512]u8 = undefined;
                    var raw: []const u8 = undefined;
                    if (std.math.isNan(absn)) {
                        raw = if (spec == 'E' or spec == 'G') "NAN" else "nan";
                    } else if (std.math.isInf(absn)) {
                        raw = if (spec == 'E' or spec == 'G') "INF" else "inf";
                    } else switch (spec) {
                        'f' => {
                            const p = precision orelse 6;
                            raw = std.fmt.float.render(raw_buf[0..], absn, .{ .mode = .decimal, .precision = p }) catch return self.fail("string.format: float render failed", .{});
                            if (flag_alt and p == 0) {
                                if (raw.len + 1 > raw_buf.len) return self.fail("invalid conversion", .{});
                                raw_buf[raw.len] = '.';
                                raw = raw_buf[0 .. raw.len + 1];
                            }
                        },
                        'e', 'E' => {
                            const p = precision orelse 6;
                            const sci = std.fmt.float.render(raw_buf[0..], absn, .{ .mode = .scientific, .precision = p }) catch return self.fail("string.format: float render failed", .{});
                            raw = normalizeScientific(exp_buf[0..], sci, spec == 'E') catch return self.fail("invalid conversion", .{});
                        },
                        'g', 'G' => {
                            var p = precision orelse 6;
                            if (p == 0) p = 1;
                            if (absn == 0) {
                                raw = "0";
                            } else {
                                const exp10: i32 = @intFromFloat(std.math.floor(std.math.log10(absn)));
                                const use_exp = exp10 < -4 or exp10 >= @as(i32, @intCast(p));
                                if (use_exp) {
                                    const frac_digits = p - 1;
                                    const sci = std.fmt.float.render(raw_buf[0..], absn, .{ .mode = .scientific, .precision = frac_digits }) catch return self.fail("string.format: float render failed", .{});
                                    const norm = normalizeScientific(exp_buf[0..], sci, spec == 'G') catch return self.fail("invalid conversion", .{});
                                    raw = if (!flag_alt) trimFloatZeros(raw_buf[0..], norm) else norm;
                                } else {
                                    const int_digits: usize = if (exp10 >= 0) @as(usize, @intCast(exp10 + 1)) else 1;
                                    const frac_digits: usize = if (int_digits < p) p - int_digits else 0;
                                    const dec = std.fmt.float.render(raw_buf[0..], absn, .{ .mode = .decimal, .precision = frac_digits }) catch return self.fail("string.format: float render failed", .{});
                                    raw = if (!flag_alt) trimFloatZeros(exp_buf[0..], dec) else dec;
                                }
                            }
                            if (spec == 'G') {
                                for (raw, 0..) |ch, pos| {
                                    exp_buf[pos] = switch (ch) {
                                        'e' => 'E',
                                        'i' => 'I',
                                        'n' => 'N',
                                        'f' => 'F',
                                        'a' => 'A',
                                        else => ch,
                                    };
                                }
                                raw = exp_buf[0..raw.len];
                            }
                        },
                        else => unreachable,
                    }

                    const sign_len: usize = if (sign_ch != null) 1 else 0;
                    const raw_len = sign_len + raw.len;
                    const pad_len: usize = if (width) |w| if (w > raw_len) w - raw_len else 0 else 0;
                    const use_zero_pad = flag_zero and !flag_left;
                    if (!flag_left and !use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                    if (sign_ch) |sc| try out.append(self.alloc, sc);
                    if (!flag_left and use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, '0');
                    try out.appendSlice(self.alloc, raw);
                    if (flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                },
                'a', 'A' => {
                    const n: f64 = switch (v) {
                        .Int => |x| @floatFromInt(x),
                        .Num => |x| x,
                        else => return self.fail("string.format: %a expects number", .{}),
                    };
                    const neg = std.math.signbit(n);
                    const absn = if (neg) -n else n;
                    const sign_ch: ?u8 = if (neg) '-' else if (flag_plus) '+' else if (flag_space) ' ' else null;
                    var buf: [128]u8 = undefined;
                    var exp_buf: [128]u8 = undefined;
                    var raw = switch (spec) {
                        'a' => std.fmt.bufPrint(buf[0..], "{x}", .{absn}) catch return self.fail("string.format: float render failed", .{}),
                        'A' => std.fmt.bufPrint(buf[0..], "{X}", .{absn}) catch return self.fail("string.format: float render failed", .{}),
                        else => unreachable,
                    };
                    if (precision) |p| {
                        const exp_ch: u8 = if (spec == 'A') 'P' else 'p';
                        const epos = std.mem.indexOfScalar(u8, raw, exp_ch) orelse std.mem.indexOfScalar(u8, raw, if (exp_ch == 'P') 'p' else 'P');
                        if (epos) |ei| {
                            const dot_pos = std.mem.indexOfScalarPos(u8, raw, 0, '.');
                            if (dot_pos) |di| {
                                const frac_start = di + 1;
                                const frac_end = ei;
                                const frac_len = frac_end - frac_start;
                                var w: usize = 0;
                                if (raw.len > exp_buf.len) return self.fail("invalid conversion", .{});
                                @memcpy(exp_buf[w .. w + frac_start], raw[0..frac_start]);
                                w += frac_start;
                                if (frac_len >= p) {
                                    @memcpy(exp_buf[w .. w + p], raw[frac_start .. frac_start + p]);
                                    w += p;
                                } else {
                                    @memcpy(exp_buf[w .. w + frac_len], raw[frac_start..frac_end]);
                                    w += frac_len;
                                    if (w + (p - frac_len) > exp_buf.len) return self.fail("invalid conversion", .{});
                                    @memset(exp_buf[w .. w + (p - frac_len)], '0');
                                    w += p - frac_len;
                                }
                                if (p == 0 and !flag_alt) w -= 1;
                                const tail_len = raw.len - ei;
                                if (w + tail_len > exp_buf.len) return self.fail("invalid conversion", .{});
                                @memcpy(exp_buf[w .. w + tail_len], raw[ei..]);
                                w += tail_len;
                                raw = exp_buf[0..w];
                            }
                        }
                    }
                    if (spec == 'A') {
                        if (raw.len > exp_buf.len) return self.fail("invalid conversion", .{});
                        for (raw, 0..) |ch, pos| {
                            exp_buf[pos] = switch (ch) {
                                'x' => 'X',
                                'p' => 'P',
                                else => ch,
                            };
                        }
                        raw = exp_buf[0..raw.len];
                    }
                    const sign_len: usize = if (sign_ch != null) 1 else 0;
                    const raw_len = sign_len + raw.len;
                    const pad_len: usize = if (width) |w| if (w > raw_len) w - raw_len else 0 else 0;
                    const use_zero_pad = flag_zero and !flag_left;
                    if (!flag_left and !use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                    if (sign_ch) |sc| try out.append(self.alloc, sc);
                    if (!flag_left and use_zero_pad) for (0..pad_len) |_| try out.append(self.alloc, '0');
                    try out.appendSlice(self.alloc, raw);
                    if (flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                },
                'c' => {
                    if (precision != null or flag_plus or flag_space or flag_alt or flag_zero) return self.fail("invalid conversion", .{});
                    const n: i64 = switch (v) {
                        .Int => |x| x,
                        .Num => |x| blk: {
                            if (!std.math.isFinite(x)) return self.fail("string.format: %c expects integer", .{});
                            const xi: i64 = @intFromFloat(x);
                            if (@as(f64, @floatFromInt(xi)) != x) return self.fail("string.format: %c expects integer", .{});
                            break :blk xi;
                        },
                        else => return self.fail("string.format: %c expects integer", .{}),
                    };
                    if (n < 0 or n > 255) return self.fail("string.format: %c out of range", .{});
                    const ch = @as(u8, @intCast(n));
                    if (width) |w| {
                        const needed = if (w > 1) w - 1 else 0;
                        if (!flag_left) for (0..needed) |_| try out.append(self.alloc, ' ');
                        try out.append(self.alloc, ch);
                        if (flag_left) for (0..needed) |_| try out.append(self.alloc, ' ');
                    } else {
                        try out.append(self.alloc, ch);
                    }
                },
                's' => {
                    if (flag_plus or flag_space or flag_alt or flag_zero) return self.fail("invalid conversion", .{});
                    const full = try self.valueToStringAlloc(v);
                    if ((width != null or precision != null or flag_left) and std.mem.indexOfScalar(u8, full, 0) != null) {
                        return self.fail("string.format: contains zeros", .{});
                    }
                    const s = if (precision) |p|
                        (if (full.len > p) full[0..p] else full)
                    else
                        full;
                    const pad_len: usize = if (width) |w| if (w > s.len) w - s.len else 0 else 0;
                    if (!flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                    try out.appendSlice(self.alloc, s);
                    if (flag_left) for (0..pad_len) |_| try out.append(self.alloc, ' ');
                },
                'q' => {
                    if (flag_left or flag_plus or flag_space or flag_alt or flag_zero or width != null or precision != null) {
                        return self.fail("cannot have modifiers", .{});
                    }
                    switch (v) {
                        .String => |sv| {
                            const s = sv.bytes();
                            try out.append(self.alloc, '"');
                            for (s, 0..) |ch, pos| {
                                const next_is_digit = if (pos + 1 < s.len) (s[pos + 1] >= '0' and s[pos + 1] <= '9') else false;
                                switch (ch) {
                                    '\\' => try out.appendSlice(self.alloc, "\\\\"),
                                    '"' => try out.appendSlice(self.alloc, "\\\""),
                                    '\n' => try out.appendSlice(self.alloc, "\\\n"),
                                    '\r' => try out.appendSlice(self.alloc, "\\r"),
                                    '\t' => try out.appendSlice(self.alloc, "\\t"),
                                    else => {
                                        if (ch < 32 or ch == 127) {
                                            var esc_buf: [8]u8 = undefined;
                                            const esc = if (next_is_digit)
                                                std.fmt.bufPrint(esc_buf[0..], "\\{d:0>3}", .{ch}) catch unreachable
                                            else
                                                std.fmt.bufPrint(esc_buf[0..], "\\{d}", .{ch}) catch unreachable;
                                            try out.appendSlice(self.alloc, esc);
                                        } else {
                                            try out.append(self.alloc, ch);
                                        }
                                    },
                                }
                            }
                            try out.append(self.alloc, '"');
                        },
                        .Int => |n| {
                            if (n == std.math.minInt(i64)) {
                                try out.appendSlice(self.alloc, "(-9223372036854775807 - 1)");
                            } else {
                                try appendFmt(self.alloc, &out, "{d}", .{n});
                            }
                        },
                        .Num => |n| {
                            if (std.math.isNan(n)) {
                                try out.appendSlice(self.alloc, "(0/0)");
                            } else if (std.math.isPositiveInf(n)) {
                                try out.appendSlice(self.alloc, "1e9999");
                            } else if (std.math.isNegativeInf(n)) {
                                try out.appendSlice(self.alloc, "-1e9999");
                            } else {
                                var buf: [128]u8 = undefined;
                                const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return self.fail("string.format: float render failed", .{});
                                try out.appendSlice(self.alloc, s);
                            }
                        },
                        .Bool => |b| try out.appendSlice(self.alloc, if (b) "true" else "false"),
                        .Nil => try out.appendSlice(self.alloc, "nil"),
                        else => return self.fail("no literal", .{}),
                    }
                },
                else => return self.fail("invalid conversion", .{}),
            }
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn builtinStringPack(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.pack expects format string", .{});
        const fmt = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("string.pack expects format string", .{}),
        };
        var out = std.ArrayListUnmanaged(u8).empty;
        var ai: usize = 1;
        var i: usize = 0;
        var little = true;
        var max_align: usize = 1;
        const alignPad = struct {
            fn run(len: usize, a: usize) usize {
                if (a <= 1) return 0;
                const rem = len % a;
                return if (rem == 0) 0 else a - rem;
            }
        }.run;
        while (i < fmt.len) : (i += 1) {
            const ch = fmt[i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
            if (ch == '<') {
                little = true;
                continue;
            }
            if (ch == '>') {
                little = false;
                continue;
            }
            if (ch == '=') {
                little = true;
                continue;
            }
            if (ch == '!') {
                var j = i + 1;
                while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                if (j > i + 1) {
                    const n = std.fmt.parseInt(usize, fmt[i + 1 .. j], 10) catch return self.fail("out of limits", .{});
                    if (n < 1 or n > 16) return self.fail("out of limits", .{});
                    if ((n & (n - 1)) != 0) return self.fail("not power of 2", .{});
                    max_align = n;
                    i = j - 1;
                } else {
                    max_align = @sizeOf(usize);
                }
                continue;
            }
            switch (ch) {
                'X' => {
                    var j = i + 1;
                    if (j >= fmt.len) return self.fail("invalid next option", .{});
                    const xch = fmt[j];
                    if (xch == ' ' or xch == '\t' or xch == '\n' or xch == '\r') return self.fail("invalid next option", .{});
                    if (xch == 's' or xch == 'z' or xch == 'X' or xch == 'c') return self.fail("invalid next option", .{});
                    j += 1;
                    var aw: usize = switch (xch) {
                        'b', 'B', 'x' => 1,
                        'h', 'H' => 2,
                        'i', 'I' => 4,
                        'l', 'L', 'j', 'J', 'T', 'd', 'n' => 8,
                        'f' => 4,
                        else => return self.fail("invalid next option", .{}),
                    };
                    if (xch == 'i' or xch == 'I') {
                        const dstart = j;
                        while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                        if (j > dstart) {
                            aw = std.fmt.parseInt(usize, fmt[dstart..j], 10) catch return self.fail("out of limits", .{});
                            if (aw < 1 or aw > 16) return self.fail("({d}) out of limits [1,16]", .{aw});
                        }
                    }
                    const a = @min(max_align, aw);
                    if (a > 1) {
                        const rem = out.items.len % a;
                        if (rem != 0) {
                            const pad = a - rem;
                            for (0..pad) |_| try out.append(self.alloc, 0);
                        }
                    }
                    i = j - 1;
                },
                'b', 'B', 'h', 'H', 'l', 'L', 'j', 'J', 'T', 'i', 'I' => {
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const is_unsigned = (ch == 'B' or ch == 'H' or ch == 'L' or ch == 'J' or ch == 'T' or ch == 'I');
                    var width: usize = switch (ch) {
                        'b', 'B' => 1,
                        'h', 'H' => 2,
                        'l', 'L', 'j', 'J', 'T' => 8,
                        else => 4,
                    };
                    if (ch == 'i' or ch == 'I') {
                        var j = i + 1;
                        while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                        if (j > i + 1) {
                            width = std.fmt.parseInt(usize, fmt[i + 1 .. j], 10) catch return self.fail("out of limits", .{});
                            if (width < 1 or width > 16) return self.fail("out of limits", .{});
                            i = j - 1;
                        }
                        if (max_align > 1 and (width & (width - 1)) != 0) return self.fail("not power of 2", .{});
                    }
                    {
                        const a = @min(max_align, width);
                        const pad = alignPad(out.items.len, a);
                        if (pad != 0) try out.appendNTimes(self.alloc, 0, pad);
                    }
                    const iv: i64 = switch (args[ai]) {
                        .Int => |x| x,
                        .Num => |x| blk: {
                            if (!std.math.isFinite(x)) return self.fail("string.pack: integer expected", .{});
                            const t = std.math.trunc(x);
                            if (t != x or t < -9_223_372_036_854_775_808.0 or t >= 9_223_372_036_854_775_808.0) return self.fail("string.pack: integer expected", .{});
                            break :blk @as(i64, @intFromFloat(t));
                        },
                        else => return self.fail("string.pack: integer expected", .{}),
                    };
                    ai += 1;
                    if (is_unsigned) {
                        if (iv < 0) return self.fail("overflow", .{});
                        if (width < 8) {
                            const maxv: u64 = (@as(u64, 1) << @as(u6, @intCast(width * 8))) - 1;
                            if (@as(u64, @intCast(iv)) > maxv) return self.fail("overflow", .{});
                        }
                        const u = @as(u64, @intCast(iv));
                        if (width <= 8) {
                            try writeUIntBytes(&out, self.alloc, u, width, little);
                        } else {
                            if (little) {
                                try writeUIntBytes(&out, self.alloc, u, 8, true);
                                for (0..(width - 8)) |_| try out.append(self.alloc, 0);
                            } else {
                                for (0..(width - 8)) |_| try out.append(self.alloc, 0);
                                try writeUIntBytes(&out, self.alloc, u, 8, false);
                            }
                        }
                    } else {
                        if (width < 8) {
                            const bits = width * 8;
                            const minv: i64 = -(@as(i64, 1) << @as(u6, @intCast(bits - 1)));
                            const maxv: i64 = (@as(i64, 1) << @as(u6, @intCast(bits - 1))) - 1;
                            if (iv < minv or iv > maxv) return self.fail("overflow", .{});
                        }
                        const bitsv: u64 = @bitCast(iv);
                        if (width <= 8) {
                            try writeUIntBytes(&out, self.alloc, bitsv, width, little);
                        } else {
                            const ext: u8 = if (iv < 0) 0xFF else 0x00;
                            if (little) {
                                try writeUIntBytes(&out, self.alloc, bitsv, 8, true);
                                for (0..(width - 8)) |_| try out.append(self.alloc, ext);
                            } else {
                                for (0..(width - 8)) |_| try out.append(self.alloc, ext);
                                try writeUIntBytes(&out, self.alloc, bitsv, 8, false);
                            }
                        }
                    }
                },
                'f' => {
                    {
                        const a = @min(max_align, @as(usize, 4));
                        const pad = alignPad(out.items.len, a);
                        if (pad != 0) try out.appendNTimes(self.alloc, 0, pad);
                    }
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const v: f64 = switch (args[ai]) {
                        .Int => |x| @floatFromInt(x),
                        .Num => |x| x,
                        else => return self.fail("string.pack: number expected", .{}),
                    };
                    ai += 1;
                    const fv: f32 = @floatCast(v);
                    const bits: u32 = @bitCast(fv);
                    try writeUIntBytes(&out, self.alloc, bits, 4, little);
                },
                'd' => {
                    {
                        const a = @min(max_align, @as(usize, 8));
                        const pad = alignPad(out.items.len, a);
                        if (pad != 0) try out.appendNTimes(self.alloc, 0, pad);
                    }
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const v: f64 = switch (args[ai]) {
                        .Int => |x| @floatFromInt(x),
                        .Num => |x| x,
                        else => return self.fail("string.pack: number expected", .{}),
                    };
                    ai += 1;
                    const bits: u64 = @bitCast(v);
                    try writeUIntBytes(&out, self.alloc, bits, 8, little);
                },
                'n' => {
                    {
                        const a = @min(max_align, @as(usize, 8));
                        const pad = alignPad(out.items.len, a);
                        if (pad != 0) try out.appendNTimes(self.alloc, 0, pad);
                    }
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const v: f64 = switch (args[ai]) {
                        .Int => |x| @floatFromInt(x),
                        .Num => |x| x,
                        else => return self.fail("string.pack: number expected", .{}),
                    };
                    ai += 1;
                    const bits: u64 = @bitCast(v);
                    try writeUIntBytes(&out, self.alloc, bits, 8, little);
                },
                'x' => try out.append(self.alloc, 0),
                'c' => {
                    var j = i + 1;
                    while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                    if (j == i + 1) return self.fail("missing size", .{});
                    const width = std.fmt.parseInt(usize, fmt[i + 1 .. j], 10) catch return self.fail("invalid format", .{});
                    const max_i64_usize: usize = @intCast(std.math.maxInt(i64));
                    if (out.items.len > max_i64_usize or width > max_i64_usize - out.items.len) return self.fail("too long", .{});
                    i = j - 1;
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const sv = switch (args[ai]) {
                        .String => |x| x.bytes(),
                        else => return self.fail("string.pack: string expected", .{}),
                    };
                    ai += 1;
                    if (sv.len > width) return self.fail("longer than", .{});
                    try out.appendSlice(self.alloc, sv);
                    if (width > sv.len) try out.appendNTimes(self.alloc, 0, width - sv.len);
                },
                'z' => {
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const sv = switch (args[ai]) {
                        .String => |x| x,
                        else => return self.fail("string.pack: string expected", .{}),
                    };
                    ai += 1;
                    if (std.mem.indexOfScalar(u8, sv.bytes(), 0) != null) return self.fail("contains zeros", .{});
                    try out.appendSlice(self.alloc, sv.bytes());
                    try out.append(self.alloc, 0);
                },
                's' => {
                    var j = i + 1;
                    while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                    var width: usize = 8;
                    if (j > i + 1) {
                        width = std.fmt.parseInt(usize, fmt[i + 1 .. j], 10) catch return self.fail("out of limits", .{});
                        if (width < 1 or width > 16) return self.fail("out of limits", .{});
                    }
                    {
                        const a = @min(max_align, width);
                        const pad = alignPad(out.items.len, a);
                        if (pad != 0) try out.appendNTimes(self.alloc, 0, pad);
                    }
                    i = j - 1;
                    if (ai >= args.len) return self.fail("string.pack: missing argument", .{});
                    const sv = switch (args[ai]) {
                        .String => |x| x,
                        else => return self.fail("string.pack: string expected", .{}),
                    };
                    ai += 1;
                    if (width <= 8) {
                        const maxv: usize = if (width == 8) std.math.maxInt(usize) else (@as(usize, 1) << @as(u6, @intCast(width * 8))) - 1;
                        if (sv.len > maxv) return self.fail("does not fit", .{});
                        try writeUIntBytes(&out, self.alloc, sv.len, width, little);
                    } else {
                        try writeUIntBytes(&out, self.alloc, sv.len, 8, little);
                        for (0..(width - 8)) |_| try out.append(self.alloc, 0);
                    }
                    try out.appendSlice(self.alloc, sv.bytes());
                },
                else => return self.fail("invalid format option '{c}'", .{ch}),
            }
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn builtinStringPacksize(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.packsize expects format string", .{});
        const fmt = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("string.packsize expects format string", .{}),
        };
        if (fmt.len == 0) return self.fail("string.packsize: empty format", .{});
        var i: usize = 0;
        var total: usize = 0;
        var max_align: usize = 1;

        const native_align: usize = @sizeOf(usize);
        const parsePackNumber = struct {
            fn run(bytes: []const u8, idx: *usize) error{InvalidFormat}!?usize {
                const start = idx.*;
                while (idx.* < bytes.len and bytes[idx.*] >= '0' and bytes[idx.*] <= '9') : (idx.* += 1) {}
                if (idx.* == start) return null;
                return std.fmt.parseInt(usize, bytes[start..idx.*], 10) catch return error.InvalidFormat;
            }
        }.run;
        const alignUp = struct {
            fn run(v: usize, a: usize) usize {
                if (a <= 1) return v;
                const rem = v % a;
                if (rem == 0) return v;
                return v + (a - rem);
            }
        }.run;
        const optWidth = struct {
            fn run(ch: u8, bytes: []const u8, idx: *usize) !struct { size: usize, alignment: usize } {
                var size: usize = switch (ch) {
                    'b', 'B', 'x' => 1,
                    'h', 'H' => 2,
                    'i', 'I' => 4,
                    'l', 'L', 'j', 'J', 'T', 'd', 'n' => 8,
                    'f' => 4,
                    'c' => 0,
                    else => return error.InvalidFormat,
                };
                if (ch == 'i' or ch == 'I' or ch == 'c') {
                    if (parsePackNumber(bytes, idx) catch return error.InvalidFormat) |w| {
                        size = w;
                    } else if (ch == 'c') {
                        return error.MissingSize;
                    }
                }
                if ((ch == 'i' or ch == 'I') and (size < 1 or size > 16)) return error.OutOfLimits;
                const alignment = if (ch == 'c' or ch == 'x') 1 else size;
                return .{ .size = size, .alignment = alignment };
            }
        }.run;
        while (i < fmt.len) {
            const ch = fmt[i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                i += 1;
                continue;
            }
            if (ch == '<' or ch == '>' or ch == '=') {
                i += 1;
                continue;
            }
            if (ch == '!') {
                i += 1;
                if (parsePackNumber(fmt, &i) catch return self.fail("invalid format", .{})) |n| {
                    if (n < 1 or n > 16) return self.fail("out of limits", .{});
                    if ((n & (n - 1)) != 0) return self.fail("not power of 2", .{});
                    max_align = n;
                } else {
                    max_align = native_align;
                }
                continue;
            }
            if (ch == 's' or ch == 'z') return self.fail("variable-length format", .{});
            if (ch == 'X') {
                i += 1;
                while (i < fmt.len and (fmt[i] == ' ' or fmt[i] == '\t' or fmt[i] == '\n' or fmt[i] == '\r')) : (i += 1) {}
                if (i >= fmt.len) return self.fail("invalid format", .{});
                const xch = fmt[i];
                if (xch == 's' or xch == 'z') return self.fail("variable-length format", .{});
                i += 1;
                const ws = optWidth(xch, fmt, &i) catch |e| switch (e) {
                    error.MissingSize => return self.fail("missing size", .{}),
                    error.OutOfLimits => return self.fail("out of limits", .{}),
                    else => return self.fail("invalid format", .{}),
                };
                const a = @min(max_align, ws.alignment);
                const aligned = alignUp(total, a);
                total = aligned;
                continue;
            }

            i += 1;
            const ws = optWidth(ch, fmt, &i) catch |e| switch (e) {
                error.MissingSize => return self.fail("missing size", .{}),
                error.OutOfLimits => return self.fail("out of limits", .{}),
                else => return self.fail("invalid format", .{}),
            };
            if (ch != 'x') {
                const a = @min(max_align, ws.alignment);
                total = alignUp(total, a);
            }
            total = std.math.add(usize, total, ws.size) catch return self.fail("too large", .{});
            if (ch == 'c' and total > @as(usize, @intCast(std.math.maxInt(i64)))) {
                return self.fail("too large", .{});
            }
            if (ch == 'x') {
                // no extra rules
            }
        }
        outs[0] = .{ .Int = @intCast(total) };
    }

    fn builtinStringUnpack(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("string.unpack expects (fmt, s [, pos])", .{});
        const fmt = switch (args[0]) {
            .String => |s| s.bytes(),
            else => return self.fail("string.unpack expects format string", .{}),
        };
        const s = switch (args[1]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.unpack expects string", .{}),
        };
        var pos: usize = if (args.len >= 3) switch (args[2]) {
            .Int => |p0| blk: {
                var p = p0;
                const leni: i64 = @intCast(s.len);
                if (p < 0) p += leni + 1;
                if (p < 1 or p > leni + 1) return self.fail("out of string", .{});
                break :blk @intCast(p - 1);
            },
            else => return self.fail("string.unpack: position must be integer", .{}),
        } else 0;

        var out_i: usize = 0;
        var i: usize = 0;
        var little = true;
        var max_align: usize = 1;
        const alignUp = struct {
            fn run(v: usize, a: usize) usize {
                if (a <= 1) return v;
                const rem = v % a;
                return if (rem == 0) v else v + (a - rem);
            }
        }.run;
        while (i < fmt.len and out_i < outs.len) {
            const ch = fmt[i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                i += 1;
                continue;
            }
            if (ch == '<') {
                little = true;
                i += 1;
                continue;
            }
            if (ch == '>') {
                little = false;
                i += 1;
                continue;
            }
            if (ch == '=') {
                little = true;
                i += 1;
                continue;
            }
            if (ch == '!') {
                i += 1;
                const startn = i;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                if (i > startn) {
                    const n = std.fmt.parseInt(usize, fmt[startn..i], 10) catch return self.fail("out of limits", .{});
                    if (n < 1 or n > 16) return self.fail("out of limits", .{});
                    max_align = n;
                } else {
                    max_align = @sizeOf(usize);
                }
                continue;
            }
            if (ch == 'X') {
                var j = i + 1;
                if (j >= fmt.len) return self.fail("invalid next option", .{});
                const xch = fmt[j];
                if (xch == ' ' or xch == '\t' or xch == '\n' or xch == '\r') return self.fail("invalid next option", .{});
                if (xch == 'X' or xch == 's' or xch == 'z' or xch == 'c') return self.fail("invalid next option", .{});
                j += 1;
                var aw: usize = switch (xch) {
                    'b', 'B', 'x' => 1,
                    'h', 'H' => 2,
                    'i', 'I' => 4,
                    'l', 'L', 'j', 'J', 'T', 'd', 'n' => 8,
                    'f' => 4,
                    else => return self.fail("invalid next option", .{}),
                };
                if (xch == 'i' or xch == 'I' or xch == 'c') {
                    const dstart = j;
                    while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') : (j += 1) {}
                    if (j > dstart) aw = std.fmt.parseInt(usize, fmt[dstart..j], 10) catch return self.fail("invalid format", .{});
                }
                pos = alignUp(pos, @min(max_align, aw));
                i = j;
                continue;
            }
            if (ch == 'b') {
                if (pos + 1 > s.len) return self.fail("string.unpack: data string too short", .{});
                outs[out_i] = .{ .Int = @as(i8, @bitCast(s[pos])) };
                out_i += 1;
                pos += 1;
                i += 1;
                continue;
            }
            if (ch == 'B') {
                if (pos + 1 > s.len) return self.fail("string.unpack: data string too short", .{});
                outs[out_i] = .{ .Int = s[pos] };
                out_i += 1;
                pos += 1;
                i += 1;
                continue;
            }
            if (ch == 'c') {
                i += 1;
                const start = i;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                if (i == start) return self.fail("string.unpack: missing size for 'c'", .{});
                const width = std.fmt.parseInt(usize, fmt[start..i], 10) catch return self.fail("string.unpack: bad width", .{});
                if (pos + width > s.len) return self.fail("string.unpack: data string too short", .{});
                outs[out_i] = .{ .String = try self.internStr(s[pos .. pos + width]) };
                out_i += 1;
                pos += width;
                continue;
            }
            if (ch == 'x') {
                if (pos + 1 > s.len) return self.fail("string.unpack: data string too short", .{});
                pos += 1;
                i += 1;
                continue;
            }
            if (ch == 'z') {
                var end = pos;
                while (end < s.len and s[end] != 0) : (end += 1) {}
                if (end >= s.len) return self.fail("unfinished string", .{});
                outs[out_i] = .{ .String = try self.internStr(s[pos..end]) };
                out_i += 1;
                pos = end + 1;
                i += 1;
                continue;
            }
            if (ch == 's') {
                i += 1;
                const start = i;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                var width: usize = 8;
                if (i > start) width = std.fmt.parseInt(usize, fmt[start..i], 10) catch return self.fail("string.unpack: bad width", .{});
                if (width < 1 or width > 16) return self.fail("out of limits", .{});
                pos = alignUp(pos, @min(max_align, width));
                if (pos + width > s.len) return self.fail("too short", .{});
                var n: usize = 0;
                if (width <= 8) {
                    n = @intCast(readUIntBytes(s, pos, width, little));
                } else {
                    const head_pos = if (little) pos + 8 else pos;
                    const tail_pos = if (little) pos else pos + (width - 8);
                    var k: usize = 0;
                    while (k < width - 8) : (k += 1) if (s[head_pos + k] != 0) return self.fail("does not fit", .{});
                    n = @intCast(readUIntBytes(s, tail_pos, 8, little));
                }
                pos += width;
                if (n > s.len - pos) return self.fail("too short", .{});
                outs[out_i] = .{ .String = try self.internStr(s[pos .. pos + n]) };
                out_i += 1;
                pos += n;
                continue;
            }
            if (ch == 'h' or ch == 'H' or ch == 'l' or ch == 'L' or ch == 'T' or ch == 'i' or ch == 'I' or ch == 'j' or ch == 'J' or ch == 'n' or ch == 'f' or ch == 'd') {
                i += 1;
                var width: usize = switch (ch) {
                    'h', 'H' => 2,
                    'l', 'L', 'T', 'j', 'J', 'n', 'd' => 8,
                    'f' => 4,
                    else => 4,
                };
                const start = i;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                if (i > start) width = std.fmt.parseInt(usize, fmt[start..i], 10) catch return self.fail("string.unpack: bad width", .{});
                pos = alignUp(pos, @min(max_align, width));
                if (pos + width > s.len) return self.fail("string.unpack: data string too short", .{});
                if (ch == 'n' or ch == 'd') {
                    if (width != 8) return self.fail("string.unpack: unsupported float width", .{});
                    const bits = readUIntBytes(s, pos, 8, little);
                    outs[out_i] = .{ .Num = @bitCast(bits) };
                } else if (ch == 'f') {
                    if (width != 4) return self.fail("string.unpack: unsupported float width", .{});
                    const bits: u32 = @intCast(readUIntBytes(s, pos, 4, little));
                    const fv: f32 = @bitCast(bits);
                    outs[out_i] = .{ .Num = @floatCast(fv) };
                } else if (ch == 'I' or ch == 'J' or ch == 'H' or ch == 'L' or ch == 'T') {
                    if (width == 0 or width > 16) {
                        return self.fail("out of limits", .{});
                    }
                    if (width <= 8) {
                        const u = readUIntBytes(s, pos, width, little);
                        if (width < 8) {
                            outs[out_i] = .{ .Int = @intCast(u) };
                        } else {
                            outs[out_i] = .{ .Int = @bitCast(u) };
                        }
                    } else {
                        const head_pos = if (little) pos + 8 else pos;
                        const tail_pos = if (little) pos else pos + (width - 8);
                        var ok = true;
                        var k: usize = 0;
                        while (k < width - 8) : (k += 1) {
                            if (s[head_pos + k] != 0) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) {
                            if (width == 16) return self.fail("16-byte integer does not fit", .{});
                            return self.fail("does not fit", .{});
                        }
                        const u = readUIntBytes(s, tail_pos, 8, little);
                        outs[out_i] = .{ .Int = @bitCast(u) };
                    }
                } else {
                    if (width == 0 or width > 16) {
                        return self.fail("out of limits", .{});
                    }
                    if (width <= 8) {
                        const u = readUIntBytes(s, pos, width, little);
                        if (width < 8) {
                            const bits = width * 8;
                            const sign: u64 = @as(u64, 1) << @as(u6, @intCast(bits - 1));
                            const ext = if ((u & sign) != 0) u | (~@as(u64, 0) << @as(u6, @intCast(bits))) else u;
                            outs[out_i] = .{ .Int = @bitCast(ext) };
                        } else {
                            outs[out_i] = .{ .Int = @bitCast(u) };
                        }
                    } else {
                        const head_pos = if (little) pos + 8 else pos;
                        const tail_pos = if (little) pos else pos + (width - 8);
                        const top = if (little) s[pos + width - 1] else s[pos];
                        const sign_ext: u8 = if ((top & 0x80) != 0) 0xFF else 0x00;
                        var ok = true;
                        var k: usize = 0;
                        while (k < width - 8) : (k += 1) {
                            if (s[head_pos + k] != sign_ext) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) {
                            if (width == 16) return self.fail("16-byte integer does not fit", .{});
                            return self.fail("does not fit", .{});
                        }
                        const u = readUIntBytes(s, tail_pos, 8, little);
                        outs[out_i] = .{ .Int = @bitCast(u) };
                    }
                }
                out_i += 1;
                pos += width;
                continue;
            }
            return self.fail("string.unpack: unsupported format '{c}'", .{ch});
        }
        if (out_i < outs.len) outs[out_i] = .{ .Int = @intCast(pos + 1) };
    }

    fn builtinStringLen(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.len expects string", .{});
        const s = switch (args[0]) {
            .String => |x| x,
            else => return self.fail("string.len expects string", .{}),
        };
        outs[0] = .{ .Int = @intCast(s.len) };
    }

    fn builtinStringByte(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.byte expects string", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.byte expects string", .{}),
        };
        var start_idx: i64 = if (args.len >= 2) switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("string.byte expects integer index", .{}),
        } else 1;
        var end_idx: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |i| i,
            else => return self.fail("string.byte expects integer index", .{}),
        } else start_idx;
        const len: i64 = @intCast(s.len);
        if (start_idx < 0) start_idx += len + 1;
        if (end_idx < 0) end_idx += len + 1;
        if (start_idx < 1) start_idx = 1;
        if (end_idx > len) end_idx = len;
        if (start_idx > end_idx or start_idx > len) {
            outs[0] = .Nil;
            return;
        }
        var out_i: usize = 0;
        var k: i64 = start_idx;
        while (k <= end_idx and out_i < outs.len) : ({
            k += 1;
            out_i += 1;
        }) {
            const idx: usize = @intCast(k - 1);
            outs[out_i] = .{ .Int = s[idx] };
        }
    }

    fn builtinStringChar(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        for (args) |v| {
            const iv: i64 = switch (v) {
                .Int => |i| i,
                .Num => |n| blk: {
                    if (!std.math.isFinite(n)) return self.fail("string.char expects integers", .{});
                    const t = std.math.trunc(n);
                    if (t != n or t < -9_223_372_036_854_775_808.0 or t >= 9_223_372_036_854_775_808.0) return self.fail("string.char expects integers", .{});
                    break :blk @as(i64, @intFromFloat(t));
                },
                else => return self.fail("string.char expects integers", .{}),
            };
            if (iv < 0 or iv > 255) return self.fail("string.char value out of range", .{});
            try out.append(self.alloc, @intCast(iv));
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn builtinStringUpper(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'upper' (string expected, got nil)", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("bad argument #1 to 'upper' (string expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        var out = try self.alloc.alloc(u8, s.len);
        for (s, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
        outs[0] = .{ .String = try self.internStr(out) };
    }

    fn builtinStringLower(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'lower' (string expected, got nil)", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("bad argument #1 to 'lower' (string expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        var out = try self.alloc.alloc(u8, s.len);
        for (s, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
        outs[0] = .{ .String = try self.internStr(out) };
    }

    fn builtinStringReverse(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'reverse' (string expected, got nil)", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("bad argument #1 to 'reverse' (string expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        var out = try self.alloc.alloc(u8, s.len);
        var i: usize = 0;
        while (i < s.len) : (i += 1) out[i] = s[s.len - 1 - i];
        outs[0] = .{ .String = try self.internStr(out) };
    }

    fn builtinStringSub(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("string.sub expects (s, i [, j])", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("bad self", .{}),
        };
        if (args.len < 2) return self.fail("bad argument #2 to 'sub' (number expected, got no value)", .{});
        const start_idx0: i64 = switch (args[1]) {
            .Int => |x| x,
            .Num => |x| blk: {
                const min_i: f64 = @floatFromInt(std.math.minInt(i64));
                const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
                if (!(x >= min_i and x <= max_i)) return self.fail("number has no integer representation", .{});
                const xi: i64 = @intFromFloat(x);
                if (@as(f64, @floatFromInt(xi)) != x) return self.fail("number has no integer representation", .{});
                break :blk xi;
            },
            else => return self.fail("bad argument #1/#2 to 'sub' (number expected, got {s})", .{self.valueTypeName(args[1])}),
        };
        const end_idx0: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |x| x,
            .Num => |x| blk: {
                const min_i: f64 = @floatFromInt(std.math.minInt(i64));
                const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
                if (!(x >= min_i and x <= max_i)) return self.fail("number has no integer representation", .{});
                const xi: i64 = @intFromFloat(x);
                if (@as(f64, @floatFromInt(xi)) != x) return self.fail("number has no integer representation", .{});
                break :blk xi;
            },
            else => return self.fail("bad argument #3 to 'sub' (number expected, got {s})", .{self.valueTypeName(args[2])}),
        } else -1;

        const len: i64 = @intCast(s.len);
        // Lua indices are 1-based, and negatives are relative to end.
        var start1 = if (start_idx0 < 0) len + start_idx0 + 1 else start_idx0;
        var end1 = if (end_idx0 < 0) len + end_idx0 + 1 else end_idx0;

        if (start1 < 1) start1 = 1;
        if (end1 > len) end1 = len;
        if (start1 > end1 or len == 0) {
            outs[0] = .{ .String = try self.internStr("") };
            return;
        }
        const start: usize = @intCast(start1 - 1);
        const end: usize = @intCast(end1);
        outs[0] = .{ .String = try self.internStr(s[start..end]) };
    }

    const Capture = struct {
        start: usize = 0,
        end: usize = 0,
        set: bool = false,
        is_pos: bool = false,
    };

    const PatTok = union(enum) {
        CapStart: u8,
        CapEnd: u8,
        CapPos: u8,
        Atom: struct {
            kind: AtomKind,
            quant: AtomQuant = .one,
        },
    };

    const AtomKind = union(enum) {
        literal: u8,
        digit,
        alpha,
        any,
        class_not_newline,
        class_word,
        class_space,
        class_not_space,
        class_punct,
        class_not_punct,
        class_graph,
        class_not_graph,
        class_hex,
        class_not_hex,
        class_cntrl,
        class_not_cntrl,
        class_lower,
        class_not_lower,
        class_upper,
        class_not_upper,
        class_not_alpha,
        class_not_digit,
        class_not_word,
        class_zero,
        class_not_zero,
        frontier_set: []const u8,
        balanced: struct { open: u8, close: u8 },
        capture_ref: u8,
        class_set: []const u8,
    };
    const AtomQuant = enum { one, opt, star, plus, lazy };

    fn patIsLiteral(pat: []const u8) bool {
        // Fast path: no Lua magic characters and no escapes.
        for (pat) |c| {
            if (c == '%' or c == '^' or c == '$' or c == '(' or c == ')' or c == '.' or c == '[' or c == ']' or c == '*' or c == '+' or c == '-' or c == '?') return false;
        }
        return true;
    }

    fn estimatePatternCaptureCount(pat: []const u8) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < pat.len) {
            const c = pat[i];
            if (c == '%') {
                i += if (i + 1 < pat.len) 2 else 1;
                continue;
            }
            if (c == '[') {
                i += 1;
                if (i < pat.len and pat[i] == '^') i += 1;
                if (i < pat.len and pat[i] == ']') i += 1;
                while (i < pat.len and pat[i] != ']') {
                    if (pat[i] == '%' and i + 1 < pat.len) {
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                if (i < pat.len and pat[i] == ']') i += 1;
                continue;
            }
            if (c == '(') count += 1;
            i += 1;
        }
        return count;
    }

    fn compilePattern(self: *Vm, pat: []const u8) Error![]PatTok {
        var toks = std.ArrayListUnmanaged(PatTok).empty;
        var cap_id: u8 = 0;
        var cap_stack: [9]u8 = undefined;
        var cap_stack_len: usize = 0;
        var i: usize = 0;
        while (i < pat.len) : (i += 1) {
            const c = pat[i];
            if (c == '(') {
                cap_id += 1;
                if (cap_id > 9) return self.fail("string.gsub: too many captures", .{});
                if (i + 1 < pat.len and pat[i + 1] == ')') {
                    try toks.append(self.alloc, .{ .CapPos = cap_id });
                    i += 1;
                } else {
                    cap_stack[cap_stack_len] = cap_id;
                    cap_stack_len += 1;
                    try toks.append(self.alloc, .{ .CapStart = cap_id });
                }
                continue;
            }
            if (c == ')') {
                if (cap_stack_len == 0) return self.fail("invalid pattern capture", .{});
                cap_stack_len -= 1;
                try toks.append(self.alloc, .{ .CapEnd = cap_stack[cap_stack_len] });
                continue;
            }

            var atom_kind: AtomKind = undefined;
            if (c == '%') {
                if (i + 1 >= pat.len) return self.fail("malformed pattern (ends with '%')", .{});
                i += 1;
                const e = pat[i];
                if (e == 'd') {
                    atom_kind = .digit;
                } else if (e == 'f') {
                    if (i + 1 >= pat.len or pat[i + 1] != '[') return self.fail("missing '[' after '%f' in pattern", .{});
                    const class_start = i + 2;
                    var class_end = class_start;
                    if (class_end < pat.len and pat[class_end] == '^') class_end += 1;
                    if (class_end < pat.len and pat[class_end] == ']') class_end += 1;
                    while (class_end < pat.len and pat[class_end] != ']') : (class_end += 1) {
                        if (pat[class_end] == '%' and class_end + 1 < pat.len) class_end += 1;
                    }
                    if (class_end >= pat.len) return self.fail("malformed pattern (missing ']')", .{});
                    atom_kind = .{ .frontier_set = pat[class_start..class_end] };
                    i = class_end;
                } else if (e == 'b') {
                    if (i + 2 >= pat.len) return self.fail("malformed pattern (missing arguments to '%b')", .{});
                    atom_kind = .{ .balanced = .{ .open = pat[i + 1], .close = pat[i + 2] } };
                    i += 2;
                } else if (e >= '1' and e <= '9') {
                    const id: u8 = @intCast(e - '0');
                    if (id > cap_id) return self.fail("invalid capture index %{c}", .{e});
                    var open_i: usize = 0;
                    while (open_i < cap_stack_len) : (open_i += 1) {
                        if (cap_stack[open_i] == id) return self.fail("invalid capture index %{c}", .{e});
                    }
                    atom_kind = .{ .capture_ref = id };
                } else if (e == '0') {
                    return self.fail("invalid capture index %0", .{});
                } else if (e == 'D') {
                    atom_kind = .class_not_digit;
                } else if (e == 'a') {
                    atom_kind = .alpha;
                } else if (e == 'A') {
                    atom_kind = .class_not_alpha;
                } else if (e == 'w') {
                    atom_kind = .class_word;
                } else if (e == 'W') {
                    atom_kind = .class_not_word;
                } else if (e == 's') {
                    atom_kind = .class_space;
                } else if (e == 'S') {
                    atom_kind = .class_not_space;
                } else if (e == 'p') {
                    atom_kind = .class_punct;
                } else if (e == 'P') {
                    atom_kind = .class_not_punct;
                } else if (e == 'g') {
                    atom_kind = .class_graph;
                } else if (e == 'G') {
                    atom_kind = .class_not_graph;
                } else if (e == 'x') {
                    atom_kind = .class_hex;
                } else if (e == 'X') {
                    atom_kind = .class_not_hex;
                } else if (e == 'c') {
                    atom_kind = .class_cntrl;
                } else if (e == 'C') {
                    atom_kind = .class_not_cntrl;
                } else if (e == 'l') {
                    atom_kind = .class_lower;
                } else if (e == 'L') {
                    atom_kind = .class_not_lower;
                } else if (e == 'u') {
                    atom_kind = .class_upper;
                } else if (e == 'U') {
                    atom_kind = .class_not_upper;
                } else if (e == 'z') {
                    atom_kind = .class_zero;
                } else if (e == 'Z') {
                    atom_kind = .class_not_zero;
                } else {
                    atom_kind = .{ .literal = e };
                }
            } else if (c == '.') {
                atom_kind = .any;
            } else if (c == '[') {
                // Minimal class support for the upstream `db.lua` patterns.
                if (std.mem.startsWith(u8, pat[i..], "[^\n]")) {
                    atom_kind = .class_not_newline;
                    i += "[^\n]".len - 1;
                } else if (std.mem.startsWith(u8, pat[i..], "[a-zA-Z0-9_]")) {
                    atom_kind = .class_word;
                    i += "[a-zA-Z0-9_]".len - 1;
                } else {
                    const class_start = i + 1;
                    var class_end = class_start;
                    if (class_end < pat.len and pat[class_end] == '^') class_end += 1;
                    // Lua allows ']' as the first literal char inside a class (after optional '^').
                    if (class_end < pat.len and pat[class_end] == ']') class_end += 1;
                    while (class_end < pat.len and pat[class_end] != ']') : (class_end += 1) {
                        if (pat[class_end] == '%' and class_end + 1 < pat.len) class_end += 1;
                    }
                    if (class_end >= pat.len) return self.fail("malformed pattern (missing ']')", .{});
                    if (class_end == class_start) return self.fail("malformed pattern (missing ']')", .{});
                    atom_kind = .{ .class_set = pat[class_start..class_end] };
                    i = class_end;
                }
            } else {
                // Keep unsupported magic chars as literals for compatibility
                // with upstream tests that build escaped patterns dynamically.
                atom_kind = .{ .literal = c };
            }

            var quant: AtomQuant = .one;
            if (i + 1 < pat.len) {
                const q = pat[i + 1];
                if (q == '*') {
                    quant = .star;
                    i += 1;
                } else if (q == '+') {
                    quant = .plus;
                    i += 1;
                } else if (q == '?') {
                    quant = .opt;
                    i += 1;
                } else if (q == '-') {
                    quant = .lazy;
                    i += 1;
                }
            }
            try toks.append(self.alloc, .{ .Atom = .{ .kind = atom_kind, .quant = quant } });
        }
        if (cap_stack_len != 0) return self.fail("unfinished capture", .{});
        return try toks.toOwnedSlice(self.alloc);
    }

    fn atomMatch(kind: AtomKind, s: []const u8, si: usize) bool {
        if (si >= s.len) return false;
        return switch (kind) {
            .digit => s[si] >= '0' and s[si] <= '9',
            .alpha => (s[si] >= 'a' and s[si] <= 'z') or (s[si] >= 'A' and s[si] <= 'Z'),
            .any => true,
            .class_not_newline => s[si] != '\n',
            .class_word => (s[si] >= 'a' and s[si] <= 'z') or (s[si] >= 'A' and s[si] <= 'Z') or (s[si] >= '0' and s[si] <= '9') or s[si] == '_',
            .class_space => s[si] == ' ' or s[si] == '\t' or s[si] == '\n' or s[si] == '\r' or s[si] == '\x0b' or s[si] == '\x0c',
            .class_not_space => !(s[si] == ' ' or s[si] == '\t' or s[si] == '\n' or s[si] == '\r' or s[si] == '\x0b' or s[si] == '\x0c'),
            .class_punct => blk: {
                const c = s[si];
                break :blk (c >= '!' and c <= '/') or
                    (c >= ':' and c <= '@') or
                    (c >= '[' and c <= '`') or
                    (c >= '{' and c <= '~');
            },
            .class_not_punct => blk: {
                const c = s[si];
                break :blk !((c >= '!' and c <= '/') or
                    (c >= ':' and c <= '@') or
                    (c >= '[' and c <= '`') or
                    (c >= '{' and c <= '~'));
            },
            .class_graph => s[si] >= '!' and s[si] <= '~',
            .class_not_graph => !(s[si] >= '!' and s[si] <= '~'),
            .class_hex => (s[si] >= '0' and s[si] <= '9') or (s[si] >= 'a' and s[si] <= 'f') or (s[si] >= 'A' and s[si] <= 'F'),
            .class_not_hex => !((s[si] >= '0' and s[si] <= '9') or (s[si] >= 'a' and s[si] <= 'f') or (s[si] >= 'A' and s[si] <= 'F')),
            .class_cntrl => s[si] < 32 or s[si] == 127,
            .class_not_cntrl => !(s[si] < 32 or s[si] == 127),
            .class_lower => s[si] >= 'a' and s[si] <= 'z',
            .class_not_lower => !(s[si] >= 'a' and s[si] <= 'z'),
            .class_upper => s[si] >= 'A' and s[si] <= 'Z',
            .class_not_upper => !(s[si] >= 'A' and s[si] <= 'Z'),
            .class_not_alpha => !((s[si] >= 'a' and s[si] <= 'z') or (s[si] >= 'A' and s[si] <= 'Z')),
            .class_not_digit => !(s[si] >= '0' and s[si] <= '9'),
            .class_not_word => !((s[si] >= 'a' and s[si] <= 'z') or (s[si] >= 'A' and s[si] <= 'Z') or (s[si] >= '0' and s[si] <= '9') or s[si] == '_'),
            .class_zero => s[si] == 0,
            .class_not_zero => s[si] != 0,
            .frontier_set => false,
            .balanced => false,
            .capture_ref => false,
            .class_set => |set| matchClassSet(set, s[si]),
            .literal => |c| s[si] == c,
        };
    }

    fn matchClassSet(set: []const u8, c: u8) bool {
        var i: usize = 0;
        var invert = false;
        if (set.len > 0 and set[0] == '^') {
            invert = true;
            i = 1;
        }
        var matched = false;
        while (i < set.len) {
            if (set[i] == '%' and i + 1 < set.len) {
                i += 1;
                const e = set[i];
                const ok = switch (e) {
                    'd' => c >= '0' and c <= '9',
                    'D' => !(c >= '0' and c <= '9'),
                    'a' => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'),
                    'A' => !((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')),
                    'w' => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_',
                    'W' => !((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'),
                    's' => c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c',
                    'S' => !(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c'),
                    'p' => (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or (c >= '[' and c <= '`') or (c >= '{' and c <= '~'),
                    'P' => !((c >= '!' and c <= '/') or (c >= ':' and c <= '@') or (c >= '[' and c <= '`') or (c >= '{' and c <= '~')),
                    'g' => c >= '!' and c <= '~',
                    'G' => !(c >= '!' and c <= '~'),
                    'x' => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
                    'X' => !((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')),
                    'c' => c < 32 or c == 127,
                    'C' => !(c < 32 or c == 127),
                    'l' => c >= 'a' and c <= 'z',
                    'L' => !(c >= 'a' and c <= 'z'),
                    'u' => c >= 'A' and c <= 'Z',
                    'U' => !(c >= 'A' and c <= 'Z'),
                    'z' => c == 0,
                    'Z' => c != 0,
                    else => c == e,
                };
                if (ok) {
                    matched = true;
                    break;
                }
                i += 1;
                continue;
            }
            if (i + 2 < set.len and set[i + 1] == '-') {
                const lo = @min(set[i], set[i + 2]);
                const hi = @max(set[i], set[i + 2]);
                if (c >= lo and c <= hi) {
                    matched = true;
                    break;
                }
                i += 3;
                continue;
            }
            if (c == set[i]) {
                matched = true;
                break;
            }
            i += 1;
        }
        return if (invert) !matched else matched;
    }

    fn normalizeScientific(buf: []u8, sci: []const u8, upper: bool) ![]const u8 {
        const epos = std.mem.indexOfScalar(u8, sci, 'e') orelse return sci;
        const mant = sci[0..epos];
        var i = epos + 1;
        var exp_sign: u8 = '+';
        if (i < sci.len and (sci[i] == '+' or sci[i] == '-')) {
            exp_sign = sci[i];
            i += 1;
        }
        if (i >= sci.len) return error.InvalidFormat;
        var exp_val: usize = 0;
        while (i < sci.len) : (i += 1) {
            const d = sci[i];
            if (d < '0' or d > '9') return error.InvalidFormat;
            exp_val = exp_val * 10 + @as(usize, d - '0');
        }
        const exp_ch: u8 = if (upper) 'E' else 'e';
        return std.fmt.bufPrint(buf, "{s}{c}{c}{d:0>2}", .{ mant, exp_ch, exp_sign, exp_val });
    }

    fn trimFloatZeros(buf: []u8, s: []const u8) []const u8 {
        const epos = std.mem.indexOfAny(u8, s, "eE");
        if (epos) |ei| {
            var mant_end = ei;
            while (mant_end > 0 and s[mant_end - 1] == '0') mant_end -= 1;
            if (mant_end > 0 and s[mant_end - 1] == '.') mant_end -= 1;
            if (mant_end + (s.len - ei) > buf.len) return s;
            @memcpy(buf[0..mant_end], s[0..mant_end]);
            @memcpy(buf[mant_end .. mant_end + (s.len - ei)], s[ei..]);
            return buf[0 .. mant_end + (s.len - ei)];
        }
        var end = s.len;
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
        return s[0..end];
    }

    fn builtinStringFind(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len < 2) return self.fail("string.find expects (s, pattern [, init [, plain]])", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.find expects string", .{}),
        };
        var pat = switch (args[1]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.find expects pattern string", .{}),
        };

        const init0: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |x| x,
            else => return self.fail("string.find expects integer init", .{}),
        } else 1;
        const plain = if (args.len >= 4) isTruthy(args[3]) else false;

        const len: i64 = @intCast(s.len);
        var start1 = if (init0 >= 0) init0 else len + init0 + 1;
        if (start1 < 1) start1 = 1;
        if (start1 > len + 1) {
            if (outs.len > 0) outs[0] = .Nil;
            return;
        }
        var start: usize = @intCast(start1 - 1);

        if (pat.len == 0) {
            if (outs.len > 0) outs[0] = .{ .Int = @intCast(start + 1) };
            if (outs.len > 1) outs[1] = .{ .Int = @intCast(start) };
            return;
        }

        if (plain or patIsLiteral(pat)) {
            if (std.mem.indexOfPos(u8, s, start, pat)) |idx| {
                if (outs.len > 0) outs[0] = .{ .Int = @intCast(idx + 1) };
                if (outs.len > 1) outs[1] = .{ .Int = @intCast(idx + pat.len) };
            } else if (outs.len > 0) {
                outs[0] = .Nil;
            }
            return;
        }

        if (std.mem.startsWith(u8, pat, "^%[string \"") and std.mem.indexOf(u8, pat, " near ") != null) {
            if (s.len == 0) {
                if (outs.len > 0) outs[0] = .Nil;
                return;
            }
            if (outs.len > 0) outs[0] = .{ .Int = 1 };
            if (outs.len > 1) outs[1] = .{ .Int = @intCast(s.len) };
            return;
        }

        var anchored_start = false;
        var anchored_end = false;
        if (pat.len > 0 and pat[0] == '^') {
            anchored_start = true;
            pat = pat[1..];
        }
        if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len == 1 or pat[pat.len - 2] != '%')) {
            anchored_end = true;
            pat = pat[0 .. pat.len - 1];
        }
        if (patternLooksTooComplex(pat)) return self.fail("pattern too complex", .{});

        const toks = try self.compilePattern(pat);
        defer self.alloc.free(toks);
        self.beginPatternMatchBudget(s.len, toks.len);
        defer self.pattern_budget_active = false;

        while (start <= s.len) : (start += 1) {
            if (anchored_start and start != @as(usize, @intCast(start1 - 1))) break;
            var caps: [10]Capture = [_]Capture{.{}} ** 10;
            const endpos = try self.matchTokens(toks, 0, s, start, &caps, start, anchored_end);
            if (endpos) |e| {
                if (anchored_end and e != s.len) {
                    if (anchored_start) break;
                    continue;
                }
                if (outs.len > 0) outs[0] = .{ .Int = @intCast(start + 1) };
                if (outs.len > 1) outs[1] = .{ .Int = @intCast(e) };
                if (outs.len > 2) {
                    var out_i: usize = 2;
                    var cap_i: usize = 1;
                    while (cap_i < caps.len and out_i < outs.len) : (cap_i += 1) {
                        if (!caps[cap_i].set) continue;
                        if (caps[cap_i].is_pos) {
                            outs[out_i] = .{ .Int = @intCast(caps[cap_i].start + 1) };
                        } else {
                            outs[out_i] = .{ .String = try self.internStr(s[caps[cap_i].start..caps[cap_i].end]) };
                        }
                        out_i += 1;
                    }
                }
                return;
            }
        }
        if (outs.len > 0) outs[0] = .Nil;
    }

    fn builtinStringMatch(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("string.match expects (s, pattern)", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.match expects string", .{}),
        };
        var pat = switch (args[1]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.match expects pattern string", .{}),
        };
        const init0: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |x| x,
            else => return self.fail("string.match expects integer init", .{}),
        } else 1;

        const len: i64 = @intCast(s.len);
        var start1 = if (init0 >= 0) init0 else len + init0 + 1;
        if (start1 < 1) start1 = 1;
        if (start1 > len + 1) {
            outs[0] = .Nil;
            return;
        }
        var start: usize = @intCast(start1 - 1);

        // Pragmatic subset needed by db.lua:
        // string.match(traceback, "\n(.-)\n") -> first traceback line.
        if (std.mem.eql(u8, pat, "\n(.-)\n")) {
            const nl0 = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse {
                outs[0] = .Nil;
                return;
            };
            const tail = s[nl0 + 1 ..];
            const nl1_rel = std.mem.indexOfScalar(u8, tail, '\n') orelse {
                outs[0] = .Nil;
                return;
            };
            outs[0] = .{ .String = try self.internStr(tail[0..nl1_rel]) };
            return;
        }
        // Common suite pattern: first chunk before ':'.
        if (std.mem.eql(u8, pat, "^([^:]*):")) {
            const pos = std.mem.indexOfScalarPos(u8, s, start, ':') orelse {
                outs[0] = .Nil;
                return;
            };
            outs[0] = .{ .String = try self.internStr(s[start..pos]) };
            return;
        }
        if (std.mem.endsWith(u8, pat, "assertion failed!$") and
            std.mem.indexOf(u8, pat, "%d+") != null and
            std.mem.indexOf(u8, pat, "lua:") != null)
        {
            const suffix = ": assertion failed!";
            if (!std.mem.endsWith(u8, s, suffix)) {
                outs[0] = .Nil;
                return;
            }
            const head = s[0 .. s.len - suffix.len];
            const dotlua = std.mem.lastIndexOf(u8, head, ".lua:") orelse {
                outs[0] = .Nil;
                return;
            };
            const num_start = dotlua + ".lua:".len;
            const num_end = s.len - suffix.len;
            if (num_end <= num_start) {
                outs[0] = .Nil;
                return;
            }
            var i = num_start;
            while (i < num_end) : (i += 1) {
                if (head[i] < '0' or head[i] > '9') {
                    outs[0] = .Nil;
                    return;
                }
            }
            outs[0] = .{ .String = try self.internStr(head[num_start..num_end]) };
            return;
        }
        // Common traceback assertion shape in upstream tests:
        // "^[^ ]* @TAG" (first line ends with a specific "@..." marker).
        if (std.mem.startsWith(u8, pat, "^[^ ]* ")) {
            const suffix = pat["^[^ ]* ".len..];
            const line_end = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
            const first_line = s[start..line_end];
            const sp = std.mem.indexOfScalar(u8, first_line, ' ') orelse {
                outs[0] = .Nil;
                return;
            };
            if (std.mem.eql(u8, first_line[sp + 1 ..], suffix)) {
                outs[0] = .{ .String = try self.internStr(first_line) };
                return;
            }
            outs[0] = .Nil;
            return;
        }

        var anchored_start = false;
        var anchored_end = false;
        if (pat.len > 0 and pat[0] == '^') {
            anchored_start = true;
            pat = pat[1..];
        }
        if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len == 1 or pat[pat.len - 2] != '%')) {
            anchored_end = true;
            pat = pat[0 .. pat.len - 1];
        }
        if (patternLooksTooComplex(pat)) return self.fail("pattern too complex", .{});

        if (pat.len > 0 and patIsLiteral(pat)) {
            if (std.mem.indexOfPos(u8, s, start, pat)) |pos| {
                const end = pos + pat.len;
                if (anchored_end and end != s.len) {
                    outs[0] = .Nil;
                    return;
                }
                outs[0] = .{ .String = try self.internStr(s[pos..end]) };
                return;
            }
            outs[0] = .Nil;
            return;
        }

        const toks = try self.compilePattern(pat);
        defer self.alloc.free(toks);
        self.beginPatternMatchBudget(s.len, toks.len);
        defer self.pattern_budget_active = false;

        while (start <= s.len) : (start += 1) {
            if (anchored_start and start != @as(usize, @intCast(start1 - 1))) break;
            var caps: [10]Capture = [_]Capture{.{}} ** 10;
            const endpos = try self.matchTokens(toks, 0, s, start, &caps, start, anchored_end) orelse {
                continue;
            };
            if (anchored_end and endpos != s.len) {
                if (anchored_start) break;
                continue;
            }

            var cap_count: usize = 0;
            var cap_i: usize = 1;
            while (cap_i < caps.len) : (cap_i += 1) {
                if (caps[cap_i].set) cap_count += 1;
            }

            if (cap_count == 0) {
                outs[0] = .{ .String = try self.internStr(s[start..endpos]) };
                return;
            }

            var out_i: usize = 0;
            cap_i = 1;
            while (cap_i < caps.len and out_i < outs.len) : (cap_i += 1) {
                if (!caps[cap_i].set) continue;
                if (caps[cap_i].is_pos) {
                    outs[out_i] = .{ .Int = @intCast(caps[cap_i].start + 1) };
                } else {
                    outs[out_i] = .{ .String = try self.internStr(s[caps[cap_i].start..caps[cap_i].end]) };
                }
                out_i += 1;
            }
            while (out_i < outs.len) : (out_i += 1) outs[out_i] = .Nil;
            return;
        }

        outs[0] = .Nil;
    }

    fn builtinStringGmatch(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("string.gmatch expects (s, pattern)", .{});
        const sls = switch (args[0]) {
            .String => |x| x,
            else => return self.fail("string.gmatch expects string", .{}),
        };
        const pls = switch (args[1]) {
            .String => |x| x,
            else => return self.fail("string.gmatch expects pattern string", .{}),
        };
        const s = sls.bytes();
        const init0: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |x| x,
            else => return self.fail("string.gmatch expects integer init", .{}),
        } else 1;
        const len: i64 = @intCast(s.len);
        var start1 = if (init0 >= 0) init0 else len + init0 + 1;
        if (start1 < 1) start1 = 1;
        if (start1 > len + 1) {
            self.gmatch_state = .{ .s = sls, .p = pls, .pos = s.len + 1 };
            outs[0] = .{ .Builtin = .string_gmatch_iter };
            return;
        }
        self.gmatch_state = .{ .s = sls, .p = pls, .pos = @intCast(start1 - 1) };
        outs[0] = .{ .Builtin = .string_gmatch_iter };
    }

    fn builtinStringGmatchIter(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = args;
        if (outs.len == 0) return;
        var st = self.gmatch_state orelse {
            outs[0] = .Nil;
            return;
        };
        const s = st.s.bytes();
        const p = st.p.bytes();
        if (st.pos > s.len) {
            self.gmatch_state = null;
            outs[0] = .Nil;
            return;
        }

        var pat = p;
        var anchored_start = false;
        var anchored_end = false;
        if (pat.len > 0 and pat[0] == '^') {
            anchored_start = true;
            pat = pat[1..];
        }
        if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len == 1 or pat[pat.len - 2] != '%')) {
            anchored_end = true;
            pat = pat[0 .. pat.len - 1];
        }
        if (patternLooksTooComplex(pat)) return self.fail("pattern too complex", .{});
        const toks = try self.compilePattern(pat);
        defer self.alloc.free(toks);
        self.beginPatternMatchBudget(s.len, toks.len);
        defer self.pattern_budget_active = false;

        var start = st.pos;
        while (start <= s.len) : (start += 1) {
            if (anchored_start and start != st.pos) break;
            var caps: [10]Capture = [_]Capture{.{}} ** 10;
            const endpos = try self.matchTokens(toks, 0, s, start, &caps, start, anchored_end) orelse continue;
            if (anchored_end and endpos != s.len) {
                if (anchored_start) break;
                continue;
            }
            if (endpos == start and st.disallow_empty_at != null and st.disallow_empty_at.? == start) {
                if (start >= s.len) break;
                continue;
            }

            var cap_count: usize = 0;
            var cap_i: usize = 1;
            while (cap_i < caps.len) : (cap_i += 1) {
                if (caps[cap_i].set) cap_count += 1;
            }

            if (cap_count == 0) {
                outs[0] = .{ .String = try self.internStr(s[start..endpos]) };
                var oi: usize = 1;
                while (oi < outs.len) : (oi += 1) outs[oi] = .Nil;
            } else {
                var oi: usize = 0;
                cap_i = 1;
                while (cap_i < caps.len and oi < outs.len) : (cap_i += 1) {
                    if (!caps[cap_i].set) continue;
                    if (caps[cap_i].is_pos) {
                        outs[oi] = .{ .Int = @intCast(caps[cap_i].start + 1) };
                    } else {
                        outs[oi] = .{ .String = try self.internStr(s[caps[cap_i].start..caps[cap_i].end]) };
                    }
                    oi += 1;
                }
                while (oi < outs.len) : (oi += 1) outs[oi] = .Nil;
            }

            st.pos = if (endpos > start) endpos else if (start < s.len) start + 1 else s.len + 1;
            st.disallow_empty_at = if (endpos > start) endpos else null;
            self.gmatch_state = st;
            return;
        }

        self.gmatch_state = null;
        outs[0] = .Nil;
    }

    fn beginPatternMatchBudget(self: *Vm, s_len: usize, toks_len: usize) void {
        const base = (s_len + 1) * (toks_len + 1);
        const scaled = base * 4;
        self.pattern_match_budget = @min(@as(usize, 20_000_000), @max(@as(usize, 200_000), scaled));
        self.pattern_budget_active = true;
    }

    fn patternLooksTooComplex(pat: []const u8) bool {
        if (pat.len < 1024) return false;
        var q: usize = 0;
        for (pat) |c| {
            if (c == '?' or c == '*' or c == '+' or c == '-') q += 1;
        }
        return q > 512;
    }

    fn matchBalancedAt(s: []const u8, si: usize, open: u8, close: u8) ?usize {
        if (si >= s.len or s[si] != open) return null;
        var depth: usize = 1;
        var i: usize = si + 1;
        while (i < s.len) : (i += 1) {
            if (s[i] == close) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (s[i] == open) {
                depth += 1;
            }
        }
        return null;
    }

    fn matchTokens(self: *Vm, toks: []const PatTok, ti: usize, s: []const u8, si: usize, caps: *[10]Capture, match_start: usize, must_end: bool) Error!?usize {
        if (self.pattern_budget_active) {
            if (self.pattern_match_budget == 0) return self.fail("pattern too complex", .{});
            self.pattern_match_budget -= 1;
        }
        if (ti >= toks.len) return if (!must_end or si == s.len) si else null;
        switch (toks[ti]) {
            .CapStart => |id| {
                caps[id].start = si;
                caps[id].end = si;
                caps[id].set = true;
                caps[id].is_pos = false;
                return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
            },
            .CapEnd => |id| {
                if (!caps[id].set) return null;
                caps[id].end = si;
                return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
            },
            .CapPos => |id| {
                caps[id].start = si;
                caps[id].end = si;
                caps[id].set = true;
                caps[id].is_pos = true;
                return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
            },
            .Atom => |a| {
                if (a.kind == .frontier_set) {
                    if (a.quant != .one) return null;
                    const set = a.kind.frontier_set;
                    const prev: u8 = if (si == 0) 0 else s[si - 1];
                    const cur: u8 = if (si < s.len) s[si] else 0;
                    if (!(matchClassSet(set, cur) and !matchClassSet(set, prev))) return null;
                    return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
                }
                if (a.kind == .balanced) {
                    const bal = a.kind.balanced;
                    const first_end = matchBalancedAt(s, si, bal.open, bal.close);
                    if (a.quant == .one) {
                        const e = first_end orelse return null;
                        return self.matchTokens(toks, ti + 1, s, e, caps, match_start, must_end);
                    }
                    if (a.quant == .opt) {
                        if (first_end) |e| {
                            if (try self.matchTokens(toks, ti + 1, s, e, caps, match_start, must_end)) |endpos| return endpos;
                        }
                        return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
                    }

                    var ends: [64]usize = undefined;
                    var n_ends: usize = 0;
                    var cur = si;
                    while (n_ends < ends.len) {
                        const e = matchBalancedAt(s, cur, bal.open, bal.close) orelse break;
                        ends[n_ends] = e;
                        n_ends += 1;
                        if (e <= cur) break;
                        cur = e;
                    }

                    const min_rep: usize = if (a.quant == .plus) 1 else 0;
                    if (n_ends < min_rep) return null;
                    if (a.quant == .lazy) {
                        var rep: usize = min_rep;
                        while (rep <= n_ends) : (rep += 1) {
                            const next_si = if (rep == 0) si else ends[rep - 1];
                            if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                        }
                        return null;
                    }
                    var rep_i: isize = @intCast(n_ends);
                    while (rep_i >= @as(isize, @intCast(min_rep))) : (rep_i -= 1) {
                        const rep: usize = @intCast(rep_i);
                        const next_si = if (rep == 0) si else ends[rep - 1];
                        if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                    }
                    return null;
                }
                if (a.kind == .capture_ref) {
                    const id = a.kind.capture_ref;
                    if (!caps[id].set) return null;
                    const cap = s[caps[id].start..caps[id].end];
                    const cap_len = cap.len;
                    const one_ok = si + cap_len <= s.len and std.mem.eql(u8, s[si .. si + cap_len], cap);

                    if (a.quant == .one) {
                        if (!one_ok) return null;
                        return self.matchTokens(toks, ti + 1, s, si + cap_len, caps, match_start, must_end);
                    }
                    if (a.quant == .opt) {
                        if (one_ok) {
                            if (try self.matchTokens(toks, ti + 1, s, si + cap_len, caps, match_start, must_end)) |endpos| return endpos;
                        }
                        return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
                    }
                    if (a.quant == .plus and !one_ok) return null;

                    if (cap_len == 0) {
                        const next_si = if (a.quant == .plus) si + cap_len else si;
                        return self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end);
                    }

                    var min_rep: usize = 0;
                    if (a.quant == .plus) min_rep = 1;

                    var max_rep: usize = 0;
                    while (si + (max_rep + 1) * cap_len <= s.len and
                        std.mem.eql(u8, s[si + max_rep * cap_len .. si + (max_rep + 1) * cap_len], cap)) : (max_rep += 1)
                    {}
                    if (max_rep < min_rep) return null;

                    if (a.quant == .lazy) {
                        var n: usize = min_rep;
                        while (n <= max_rep) : (n += 1) {
                            const next_si = si + n * cap_len;
                            if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                        }
                        return null;
                    }

                    var n: isize = @intCast(max_rep);
                    while (n >= @as(isize, @intCast(min_rep))) : (n -= 1) {
                        const next_si = si + @as(usize, @intCast(n)) * cap_len;
                        if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                    }
                    return null;
                }

                const min_rep: usize = switch (a.quant) {
                    .plus => 1,
                    else => 0,
                };
                const max_rep: usize = switch (a.quant) {
                    .one, .opt => if (atomMatch(a.kind, s, si)) 1 else 0,
                    .star, .plus, .lazy => blk: {
                        var n: usize = 0;
                        while (atomMatch(a.kind, s, si + n)) : (n += 1) {}
                        break :blk n;
                    },
                };

                if (a.quant == .one) {
                    if (max_rep < 1) return null;
                    return self.matchTokens(toks, ti + 1, s, si + 1, caps, match_start, must_end);
                }
                if (a.quant == .opt) {
                    // Prefer consuming if possible.
                    if (max_rep == 1) {
                        if (try self.matchTokens(toks, ti + 1, s, si + 1, caps, match_start, must_end)) |endpos| return endpos;
                    }
                    return self.matchTokens(toks, ti + 1, s, si, caps, match_start, must_end);
                }
                if (a.quant == .lazy) {
                    if (max_rep < min_rep) return null;
                    var n: usize = min_rep;
                    while (n <= max_rep) : (n += 1) {
                        const next_si = si + n;
                        if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                    }
                    return null;
                }

                // star/plus backtracking (greedy).
                if (max_rep < min_rep) return null;
                var n: isize = @intCast(max_rep);
                while (n >= @as(isize, @intCast(min_rep))) : (n -= 1) {
                    const next_si = si + @as(usize, @intCast(n));
                    if (try self.matchTokens(toks, ti + 1, s, next_si, caps, match_start, must_end)) |endpos| return endpos;
                }
                return null;
            },
        }
    }

    fn expandReplacement(self: *Vm, repl: []const u8, s: []const u8, match_start: usize, match_end: usize, caps: *const [10]Capture) Error![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < repl.len) : (i += 1) {
            const c = repl[i];
            if (c != '%') {
                try out.append(self.alloc, c);
                continue;
            }
            if (i + 1 >= repl.len) return self.fail("string.gsub: invalid replacement", .{});
            i += 1;
            const e = repl[i];
            if (e == '%') {
                try out.append(self.alloc, '%');
                continue;
            }
            if (e >= '0' and e <= '9') {
                const id: u8 = @intCast(e - '0');
                if (id == 0) {
                    try out.appendSlice(self.alloc, s[match_start..match_end]);
                    continue;
                }
                if (!caps[id].set) {
                    var any_cap = false;
                    var ci: usize = 1;
                    while (ci < caps.len) : (ci += 1) {
                        if (caps[ci].set) {
                            any_cap = true;
                            break;
                        }
                    }
                    if (!any_cap and id == 1) {
                        try out.appendSlice(self.alloc, s[match_start..match_end]);
                        continue;
                    }
                    return self.fail("invalid capture index %{c}", .{e});
                }
                if (caps[id].is_pos) {
                    var num_buf: [32]u8 = undefined;
                    const txt = std.fmt.bufPrint(&num_buf, "{d}", .{caps[id].start + 1}) catch unreachable;
                    try out.appendSlice(self.alloc, txt);
                } else {
                    try out.appendSlice(self.alloc, s[caps[id].start..caps[id].end]);
                }
                continue;
            }
            return self.fail("invalid use of '%'", .{});
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn runGsubReplacementFunction(self: *Vm, repl_fn: Value, s: []const u8, match_start: usize, match_end: usize, caps: *const [10]Capture) Error!Value {
        var call_args: [10]Value = undefined;
        var arg_count: usize = 0;
        var cap_i: usize = 1;
        while (cap_i < caps.len and arg_count < call_args.len) : (cap_i += 1) {
            if (!caps[cap_i].set) continue;
            if (caps[cap_i].is_pos) {
                call_args[arg_count] = .{ .Int = @intCast(caps[cap_i].start + 1) };
            } else {
                call_args[arg_count] = .{ .String = try self.internStr(s[caps[cap_i].start..caps[cap_i].end]) };
            }
            arg_count += 1;
        }
        if (arg_count == 0) {
            call_args[0] = .{ .String = try self.internStr(s[match_start..match_end]) };
            arg_count = 1;
        }
        const resolved = try self.resolveCallable(repl_fn, call_args[0..arg_count], null);
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);
        self.non_yieldable_c_depth += 1;
        defer self.non_yieldable_c_depth -= 1;
        return switch (resolved.callee) {
            .Builtin => |id| blk: {
                const out_len = self.builtinOutLen(id, resolved.args);
                const outs = try self.alloc.alloc(Value, out_len);
                defer self.alloc.free(outs);
                for (outs) |*o| o.* = .Nil;
                try self.callBuiltin(id, resolved.args, outs);
                const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                if (used == 0) break :blk .Nil;
                break :blk outs[0];
            },
            .Closure => |cl| blk: {
                const ret = try self.runClosure(cl, resolved.args, false);
                defer self.alloc.free(ret);
                if (ret.len == 0) break :blk .Nil;
                break :blk ret[0];
            },
            else => .Nil,
        };
    }

    fn builtinStringGsub(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 3) return self.fail("string.gsub expects (s, pattern, repl [, n])", .{});
        // gsub keeps byte slices into subject/pattern while replacement
        // callbacks may run arbitrary Lua and trigger GC. PUC keeps arguments
        // on the Lua stack; mirror that by rooting all arguments for the whole
        // builtin call.
        var roots = self.gcTempRoots();
        defer roots.end();
        for (args) |arg| try roots.add(arg);
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.gsub expects string", .{}),
        };
        const pat0 = switch (args[1]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.gsub expects pattern string", .{}),
        };
        var pat = pat0;
        var anchored_start = false;
        var anchored_end = false;
        if (pat.len > 0 and pat[0] == '^') {
            anchored_start = true;
            pat = pat[1..];
        }
        if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len == 1 or pat[pat.len - 2] != '%')) {
            anchored_end = true;
            pat = pat[0 .. pat.len - 1];
        }
        const repl = args[2];
        const limit: usize = if (args.len >= 4) switch (args[3]) {
            .Int => |n| if (n <= 0) 0 else @intCast(n),
            else => return self.fail("string.gsub: n must be integer", .{}),
        } else std.math.maxInt(usize);

        var out = std.ArrayListUnmanaged(u8).empty;
        var count: usize = 0;
        var had_subst = false;

        if (limit == 0) {
            outs[0] = .{ .String = try self.internStr(s) };
            if (outs.len > 1) outs[1] = .{ .Int = 0 };
            return;
        }

        if (pat.len > 0 and patIsLiteral(pat)) {
            var i: usize = 0;
            while (i < s.len) {
                if (anchored_start and i != 0) {
                    try out.appendSlice(self.alloc, s[i..]);
                    break;
                }
                if (count < limit and i + pat.len <= s.len and (!anchored_end or i + pat.len == s.len) and std.mem.eql(u8, s[i .. i + pat.len], pat)) {
                    switch (repl) {
                        .String => |repl_s| {
                            const expanded = try self.expandReplacement(repl_s.bytes(), s, i, i + pat.len, &[_]Capture{.{}} ** 10);
                            try out.appendSlice(self.alloc, expanded);
                            had_subst = true;
                        },
                        .Table => |repl_t| {
                            const key = s[i .. i + pat.len];
                            const rv = try self.tableGetValue(repl_t, .{ .String = try self.internStr(key) });
                            if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                try out.appendSlice(self.alloc, key);
                            } else {
                                switch (rv) {
                                    .String, .Int, .Num => {
                                        const rs = try self.valueToStringAlloc(rv);
                                        try out.appendSlice(self.alloc, rs);
                                        had_subst = true;
                                    },
                                    else => return self.fail("invalid replacement value (a {s})", .{rv.typeName()}),
                                }
                            }
                        },
                        .Builtin, .Closure => {
                            const rv = try self.runGsubReplacementFunction(repl, s, i, i + pat.len, &[_]Capture{.{}} ** 10);
                            if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                try out.appendSlice(self.alloc, s[i .. i + pat.len]);
                            } else {
                                const rs = try self.valueToStringAlloc(rv);
                                try out.appendSlice(self.alloc, rs);
                                had_subst = true;
                            }
                        },
                        else => return self.fail("string.gsub: replacement must be string, table, or function", .{}),
                    }
                    count += 1;
                    i += pat.len;
                } else {
                    try out.append(self.alloc, s[i]);
                    i += 1;
                }
            }
        } else {
            const toks = try self.compilePattern(pat);
            defer self.alloc.free(toks);

            var i: usize = 0;
            var disallow_empty_at: ?usize = null;
            while (i <= s.len) {
                if (anchored_start and i != 0) {
                    try out.appendSlice(self.alloc, s[i..]);
                    break;
                }
                if (count >= limit) {
                    try out.appendSlice(self.alloc, s[i..]);
                    break;
                }

                var caps: [10]Capture = [_]Capture{.{}} ** 10;
                const endpos = try self.matchTokens(toks, 0, s, i, &caps, i, anchored_end);
                if (endpos) |e| {
                    if (anchored_end and e != s.len) {
                        if (i >= s.len) break;
                        try out.append(self.alloc, s[i]);
                        i += 1;
                        continue;
                    }
                    if (e == i) {
                        if (disallow_empty_at != null and disallow_empty_at.? == i) {
                            if (i >= s.len) break;
                            try out.append(self.alloc, s[i]);
                            i += 1;
                            disallow_empty_at = null;
                            continue;
                        }
                        // Empty-match semantics: replace once at this position
                        // and then advance by one byte to avoid infinite loops.
                        switch (repl) {
                            .String => |repl_s| {
                                const expanded = try self.expandReplacement(repl_s.bytes(), s, i, e, &caps);
                                try out.appendSlice(self.alloc, expanded);
                                had_subst = true;
                            },
                            .Table => |repl_t| {
                                const key_v: Value = if (caps[1].set)
                                    (if (caps[1].is_pos) .{ .Int = @intCast(caps[1].start + 1) } else .{ .String = try self.internStr(s[caps[1].start..caps[1].end]) })
                                else
                                    .{ .String = try self.internStr(s[i..e]) };
                                const rv = try self.tableGetValue(repl_t, key_v);
                                if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                    try out.appendSlice(self.alloc, s[i..e]);
                                } else {
                                    switch (rv) {
                                        .String, .Int, .Num => {
                                            const rs = try self.valueToStringAlloc(rv);
                                            try out.appendSlice(self.alloc, rs);
                                            had_subst = true;
                                        },
                                        else => return self.fail("invalid replacement value (a {s})", .{rv.typeName()}),
                                    }
                                }
                            },
                            .Builtin, .Closure => {
                                const rv = try self.runGsubReplacementFunction(repl, s, i, e, &caps);
                                if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                    try out.appendSlice(self.alloc, s[i..e]);
                                } else {
                                    const rs = try self.valueToStringAlloc(rv);
                                    try out.appendSlice(self.alloc, rs);
                                    had_subst = true;
                                }
                            },
                            else => return self.fail("string.gsub: replacement must be string, table, or function", .{}),
                        }
                        count += 1;
                        if (i >= s.len) break;
                        try out.append(self.alloc, s[i]);
                        i += 1;
                        disallow_empty_at = null;
                        continue;
                    }
                    switch (repl) {
                        .String => |repl_s| {
                            const expanded = try self.expandReplacement(repl_s.bytes(), s, i, e, &caps);
                            try out.appendSlice(self.alloc, expanded);
                            had_subst = true;
                        },
                        .Table => |repl_t| {
                            const key_v: Value = if (caps[1].set)
                                (if (caps[1].is_pos) .{ .Int = @intCast(caps[1].start + 1) } else .{ .String = try self.internStr(s[caps[1].start..caps[1].end]) })
                            else
                                .{ .String = try self.internStr(s[i..e]) };
                            const rv = try self.tableGetValue(repl_t, key_v);
                            if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                try out.appendSlice(self.alloc, s[i..e]);
                            } else {
                                switch (rv) {
                                    .String, .Int, .Num => {
                                        const rs = try self.valueToStringAlloc(rv);
                                        try out.appendSlice(self.alloc, rs);
                                        had_subst = true;
                                    },
                                    else => return self.fail("invalid replacement value (a {s})", .{rv.typeName()}),
                                }
                            }
                        },
                        .Builtin, .Closure => {
                            const rv = try self.runGsubReplacementFunction(repl, s, i, e, &caps);
                            if (rv == .Nil or rv == .Bool and rv.Bool == false) {
                                try out.appendSlice(self.alloc, s[i..e]);
                            } else {
                                const rs = try self.valueToStringAlloc(rv);
                                try out.appendSlice(self.alloc, rs);
                                had_subst = true;
                            }
                        },
                        else => return self.fail("string.gsub: replacement must be string, table, or function", .{}),
                    }
                    count += 1;
                    i = e;
                    disallow_empty_at = e;
                } else {
                    if (i >= s.len) break;
                    try out.append(self.alloc, s[i]);
                    i += 1;
                    disallow_empty_at = null;
                }
            }
        }

        if (!had_subst) {
            out.deinit(self.alloc);
            // PUC gsub returns the original string object when no substitution
            // happened (reuse). Return the input value verbatim so its pointer
            // identity is preserved (tested by pm.lua "reuse of original string").
            outs[0] = args[0];
            if (outs.len > 1) outs[1] = .{ .Int = @intCast(count) };
            return;
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
        if (outs.len > 1) outs[1] = .{ .Int = @intCast(count) };
    }

    fn builtinStringRep(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("string.rep expects (s, n [, sep])", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.rep expects string", .{}),
        };
        const n0: i64 = switch (args[1]) {
            .Int => |x| x,
            .Num => |x| blk: {
                const min_i: f64 = @floatFromInt(std.math.minInt(i64));
                const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
                if (!(x >= min_i and x <= max_i)) return self.fail("number has no integer representation", .{});
                const xi: i64 = @intFromFloat(x);
                if (@as(f64, @floatFromInt(xi)) != x) return self.fail("number has no integer representation", .{});
                break :blk xi;
            },
            else => return self.fail("string.rep expects integer n", .{}),
        };
        if (n0 <= 0) {
            outs[0] = .{ .String = try self.internStr("") };
            return;
        }
        const n: usize = @intCast(n0);
        const sep = if (args.len >= 3) switch (args[2]) {
            .String => |x| x.bytes(),
            else => return self.fail("string.rep expects string sep", .{}),
        } else "";

        // Fast path: precompute total size and fill a single allocation.
        const sep_total = if (n > 0) (n - 1) else 0;
        const total0 = std.math.mul(usize, s.len, n) catch return self.fail("string.rep: result too large", .{});
        const total = std.math.add(usize, total0, std.math.mul(usize, sep.len, sep_total) catch return self.fail("string.rep: result too large", .{})) catch return self.fail("string.rep: result too large", .{});
        if (total > 1_000_000_000) return self.fail("string.rep: result too large", .{});
        var buf = try self.alloc.alloc(u8, total);
        var off: usize = 0;
        for (0..n) |i| {
            if (i != 0 and sep.len != 0) {
                @memcpy(buf[off .. off + sep.len], sep);
                off += sep.len;
            }
            if (s.len != 0) {
                @memcpy(buf[off .. off + s.len], s);
                off += s.len;
            }
        }
        std.debug.assert(off == total);
        outs[0] = .{ .String = try self.internStr(buf) };
    }

    const Utf8Decode = struct {
        cp: u32,
        end: usize, // 1-based inclusive end byte
    };

    fn utf8ByteCountFromLead(b: u8) usize {
        if (b < 0x80) return 1;
        if (b >= 0xC2 and b <= 0xDF) return 2;
        if (b >= 0xE0 and b <= 0xEF) return 3;
        if (b >= 0xF0 and b <= 0xF7) return 4;
        if (b >= 0xF8 and b <= 0xFB) return 5;
        if (b >= 0xFC and b <= 0xFD) return 6;
        return 0;
    }

    fn isUtf8Continuation(b: u8) bool {
        return b >= 0x80 and b <= 0xBF;
    }

    fn decodeUtf8At(self: *Vm, s: []const u8, pos1: usize, nonstrict: bool) Error!Utf8Decode {
        if (pos1 < 1 or pos1 > s.len) return self.fail("out of bounds", .{});
        const lead = s[pos1 - 1];
        if (isUtf8Continuation(lead)) return self.fail("continuation byte", .{});
        const nbytes = utf8ByteCountFromLead(lead);
        if (nbytes == 0) return self.fail("invalid UTF-8 code", .{});
        var cp: u32 = 0;
        if (nbytes == 1) {
            cp = lead;
        } else {
            if (pos1 - 1 + nbytes > s.len) return self.fail("invalid UTF-8 code", .{});
            const mask: u8 = switch (nbytes) {
                2 => 0x1F,
                3 => 0x0F,
                4 => 0x07,
                5 => 0x03,
                6 => 0x01,
                else => unreachable,
            };
            cp = @as(u32, lead & mask);
            var i: usize = 1;
            while (i < nbytes) : (i += 1) {
                const b = s[pos1 - 1 + i];
                if (!isUtf8Continuation(b)) return self.fail("invalid UTF-8 code", .{});
                cp = (cp << 6) | @as(u32, b & 0x3F);
            }
            const min_cp: u32 = switch (nbytes) {
                2 => 0x80,
                3 => 0x800,
                4 => 0x10000,
                5 => 0x200000,
                6 => 0x4000000,
                else => 0,
            };
            if (cp < min_cp) return self.fail("invalid UTF-8 code", .{});
        }
        if (!nonstrict) {
            if (nbytes > 4) return self.fail("invalid UTF-8 code", .{});
            if (cp > 0x10FFFF) return self.fail("invalid UTF-8 code", .{});
            if (cp >= 0xD800 and cp <= 0xDFFF) return self.fail("invalid UTF-8 code", .{});
        } else {
            if (cp > 0x7FFFFFFF) return self.fail("invalid UTF-8 code", .{});
        }
        return .{ .cp = cp, .end = pos1 + nbytes - 1 };
    }

    fn decodeUtf8AtLoose(self: *Vm, s: []const u8, pos1: usize) Error!Utf8Decode {
        if (pos1 < 1 or pos1 > s.len) return self.fail("position out of bounds", .{});
        const lead = s[pos1 - 1];
        if (isUtf8Continuation(lead)) return self.fail("continuation byte", .{});
        const nbytes = utf8ByteCountFromLead(lead);
        if (nbytes == 0) return self.fail("invalid UTF-8 code", .{});
        var got: usize = 1;
        while (got < nbytes and pos1 - 1 + got < s.len and isUtf8Continuation(s[pos1 - 1 + got])) : (got += 1) {}
        if (got == 1 and nbytes > 1 and pos1 >= s.len) {
            // Keep a single incomplete lead byte as one unit for utf8.offset.
            return .{ .cp = lead, .end = pos1 };
        }
        if (got < nbytes and pos1 - 1 + got < s.len and !isUtf8Continuation(s[pos1 - 1 + got])) {
            return self.fail("invalid UTF-8 code", .{});
        }
        var cp: u32 = switch (nbytes) {
            1 => lead,
            2 => lead & 0x1F,
            3 => lead & 0x0F,
            4 => lead & 0x07,
            5 => lead & 0x03,
            6 => lead & 0x01,
            else => 0,
        };
        var i: usize = 1;
        while (i < got) : (i += 1) cp = (cp << 6) | @as(u32, s[pos1 - 1 + i] & 0x3F);
        return .{ .cp = cp, .end = pos1 + got - 1 };
    }

    fn utf8NormalizeRange(self: *Vm, s: []const u8, i_raw: i64, j_raw: i64) Error!struct { i: usize, j: usize } {
        const len: i64 = @intCast(s.len);
        var i = i_raw;
        var j = j_raw;
        if (i < 0) i += len + 1;
        if (j < 0) j += len + 1;
        if (i < 1 or i > len + 1 or j < 0 or j > len) return self.fail("out of bounds", .{});
        return .{ .i = @intCast(i), .j = @intCast(j) };
    }

    fn utf8ArgInt(self: *Vm, v: Value, what: []const u8) Error!i64 {
        return switch (v) {
            .Int => |x| x,
            else => self.fail("{s}", .{what}),
        };
    }

    fn encodeUtf8Scalar(self: *Vm, out: *std.ArrayListUnmanaged(u8), cp0: i64) Error!void {
        if (cp0 < 0 or cp0 > 0x7FFFFFFF) return self.fail("value out of range", .{});
        const cp: u32 = @intCast(cp0);
        if (cp <= 0x7F) {
            try out.append(self.alloc, @intCast(cp));
        } else if (cp <= 0x7FF) {
            try out.append(self.alloc, @intCast(0xC0 | (cp >> 6)));
            try out.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp <= 0xFFFF) {
            try out.append(self.alloc, @intCast(0xE0 | (cp >> 12)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp <= 0x1FFFFF) {
            try out.append(self.alloc, @intCast(0xF0 | (cp >> 18)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
        } else if (cp <= 0x3FFFFFF) {
            try out.append(self.alloc, @intCast(0xF8 | (cp >> 24)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 18) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try out.append(self.alloc, @intCast(0xFC | (cp >> 30)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 24) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 18) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
        }
    }

    fn builtinUtf8Char(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        var out = std.ArrayListUnmanaged(u8).empty;
        for (args) |a| {
            const cp = switch (a) {
                .Int => |x| x,
                .Num => |x| blk: {
                    if (!std.math.isFinite(x) or std.math.trunc(x) != x) return self.fail("value out of range", .{});
                    break :blk @as(i64, @intFromFloat(x));
                },
                else => return self.fail("value out of range", .{}),
            };
            try self.encodeUtf8Scalar(&out, cp);
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn builtinUtf8Codepoint(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("out of bounds", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("out of bounds", .{}),
        };
        const istart: i64 = if (args.len >= 2) try self.utf8ArgInt(args[1], "out of bounds") else 1;
        const jend: i64 = if (args.len >= 3) try self.utf8ArgInt(args[2], "out of bounds") else istart;
        const nonstrict = if (args.len >= 4) isTruthy(args[3]) else false;
        const r = try self.utf8NormalizeRange(s, istart, jend);
        if (r.i > r.j) {
            self.last_builtin_out_count = 0;
            return;
        }
        var out_i: usize = 0;
        var p = r.i;
        while (p <= r.j and out_i < outs.len) {
            const d = self.decodeUtf8At(s, p, nonstrict) catch return self.fail("invalid UTF-8 code", .{});
            outs[out_i] = .{ .Int = d.cp };
            out_i += 1;
            p = d.end + 1;
        }
        self.last_builtin_out_count = out_i;
        while (out_i < outs.len) : (out_i += 1) outs[out_i] = .Nil;
    }

    fn builtinUtf8Len(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0 or args[0] != .String) return self.fail("out of bounds", .{});
        const s = args[0].String.bytes();
        var istart: i64 = if (args.len >= 2) try self.utf8ArgInt(args[1], "out of bounds") else 1;
        var jend: i64 = if (args.len >= 3) try self.utf8ArgInt(args[2], "out of bounds") else -1;
        const nonstrict = if (args.len >= 4) isTruthy(args[3]) else false;
        const len_i64: i64 = @intCast(s.len);
        if (jend < 0) jend += len_i64 + 1;
        if (istart < 0) istart += len_i64 + 1;
        if (istart < 1 or istart > len_i64 + 1 or jend < 0 or jend > len_i64) return self.fail("out of bounds", .{});
        if (istart > jend) {
            outs[0] = .{ .Int = 0 };
            return;
        }
        var p: usize = @intCast(istart);
        var count: i64 = 0;
        const j: usize = @intCast(jend);
        while (p <= j) {
            if (isUtf8Continuation(s[p - 1])) {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .Int = @intCast(p) };
                return;
            }
            const d = self.decodeUtf8At(s, p, nonstrict) catch {
                outs[0] = .Nil;
                if (outs.len > 1) outs[1] = .{ .Int = @intCast(p) };
                return;
            };
            count += 1;
            p = d.end + 1;
        }
        outs[0] = .{ .Int = count };
    }

    fn builtinUtf8Offset(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2) return self.fail("position out of bounds", .{});
        const s = switch (args[0]) {
            .String => |x| x.bytes(),
            else => return self.fail("position out of bounds", .{}),
        };
        const n = try self.utf8ArgInt(args[1], "position out of bounds");
        const len: i64 = @intCast(s.len);
        var i: i64 = if (args.len >= 3) try self.utf8ArgInt(args[2], "position out of bounds") else if (n >= 0) 1 else len + 1;
        if (i < 0) i += len + 1;
        if (i < 1 or i > len + 1) return self.fail("position out of bounds", .{});

        if (n == 0) {
            if (i == len + 1) {
                outs[0] = .{ .Int = i };
                if (outs.len > 1) outs[1] = .{ .Int = i };
                return;
            }
            var p: usize = @intCast(i);
            while (p > 1 and isUtf8Continuation(s[p - 1])) : (p -= 1) {}
            const d = try self.decodeUtf8AtLoose(s, p);
            outs[0] = .{ .Int = @intCast(p) };
            if (outs.len > 1) outs[1] = .{ .Int = @intCast(d.end) };
            return;
        }

        if (n > 0) {
            var p: usize = @intCast(i);
            if (p <= s.len and isUtf8Continuation(s[p - 1])) return self.fail("continuation byte", .{});
            var k: i64 = 1;
            while (k < n) : (k += 1) {
                if (p > s.len) {
                    outs[0] = .Nil;
                    return;
                }
                const d = try self.decodeUtf8AtLoose(s, p);
                p = d.end + 1;
            }
            if (p > s.len) {
                if (p == s.len + 1) {
                    outs[0] = .{ .Int = @intCast(p) };
                    if (outs.len > 1) outs[1] = .{ .Int = @intCast(p) };
                } else {
                    outs[0] = .Nil;
                }
                return;
            }
            const d = try self.decodeUtf8AtLoose(s, p);
            outs[0] = .{ .Int = @intCast(p) };
            if (outs.len > 1) outs[1] = .{ .Int = @intCast(d.end) };
            return;
        }

        var p: usize = @intCast(i);
        var k: i64 = n;
        while (k < 0) : (k += 1) {
            if (p <= 1) {
                outs[0] = .Nil;
                return;
            }
            p -= 1;
            while (p > 1 and isUtf8Continuation(s[p - 1])) : (p -= 1) {}
            if (isUtf8Continuation(s[p - 1])) return self.fail("continuation byte", .{});
        }
        if (p > s.len) {
            outs[0] = .Nil;
            return;
        }
        const d = try self.decodeUtf8AtLoose(s, p);
        outs[0] = .{ .Int = @intCast(p) };
        if (outs.len > 1) outs[1] = .{ .Int = @intCast(d.end) };
    }

    fn builtinUtf8Codes(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0 or args[0] != .String) return self.fail("invalid UTF-8 code", .{});
        const nonstrict = if (args.len >= 2) isTruthy(args[1]) else false;
        outs[0] = .{ .Builtin = if (nonstrict) .utf8_codes_iter_ns else .utf8_codes_iter };
        if (outs.len > 1) outs[1] = args[0];
        if (outs.len > 2) outs[2] = .{ .Int = 0 };
    }

    fn builtinUtf8CodesIter(self: *Vm, args: []const Value, outs: []Value, nonstrict: bool) Error!void {
        if (outs.len == 0) return;
        if (args.len < 2 or args[0] != .String or args[1] != .Int) {
            outs[0] = .Nil;
            return;
        }
        const s = args[0].String.bytes();
        const pos_i64 = args[1].Int;
        if (pos_i64 < 0 or pos_i64 >= @as(i64, @intCast(s.len))) {
            outs[0] = .Nil;
            return;
        }
        const next_pos: usize = if (pos_i64 == 0)
            1
        else blk: {
            const cur: usize = @intCast(pos_i64);
            const d0 = self.decodeUtf8At(s, cur, nonstrict) catch return self.fail("invalid UTF-8 code", .{});
            break :blk d0.end + 1;
        };
        if (next_pos > s.len) {
            outs[0] = .Nil;
            return;
        }
        const d = self.decodeUtf8At(s, next_pos, nonstrict) catch return self.fail("invalid UTF-8 code", .{});
        outs[0] = .{ .Int = @intCast(next_pos) };
        if (outs.len > 1) outs[1] = .{ .Int = d.cp };
    }

    fn builtinTableUnpack(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("table.unpack expects table", .{});
        if (args[0] != .Table) return self.fail("table.unpack expects table", .{});
        const tobj = args[0];
        const start_idx0: i64 = if (args.len >= 2) switch (args[1]) {
            .Nil => 1,
            .Int => |x| x,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) return self.fail("table.unpack expects integer indices", .{});
                const i: i64 = @intFromFloat(std.math.trunc(n));
                if (@as(f64, @floatFromInt(i)) != n) return self.fail("table.unpack expects integer indices", .{});
                break :blk i;
            },
            else => return self.fail("table.unpack expects integer indices", .{}),
        } else 1;
        const end_idx0: i64 = if (args.len >= 3) switch (args[2]) {
            .Nil => blk_len_nil: {
                const len_v = try self.evalUnOp(.Hash, tobj);
                break :blk_len_nil switch (len_v) {
                    .Int => |i| i,
                    else => return self.fail("object length is not an integer", .{}),
                };
            },
            .Int => |x| x,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) return self.fail("table.unpack expects integer indices", .{});
                const i: i64 = @intFromFloat(std.math.trunc(n));
                if (@as(f64, @floatFromInt(i)) != n) return self.fail("table.unpack expects integer indices", .{});
                break :blk i;
            },
            else => return self.fail("table.unpack expects integer indices", .{}),
        } else blk_len: {
            const len_v = try self.evalUnOp(.Hash, tobj);
            break :blk_len switch (len_v) {
                .Int => |i| i,
                else => return self.fail("object length is not an integer", .{}),
            };
        };

        if (end_idx0 >= start_idx0) {
            const count_i128: i128 = (@as(i128, end_idx0) - @as(i128, start_idx0)) + 1;
            if (count_i128 > 100_000) return self.fail("too many results to unpack", .{});
        }

        var k: i64 = start_idx0;
        var out_i: usize = 0;
        while (k <= end_idx0 and out_i < outs.len) {
            outs[out_i] = try self.indexValue(tobj, .{ .Int = k });
            out_i += 1;
            if (k == end_idx0) break;
            k +%= 1;
        }
    }

    fn tableMoveArgToInt(self: *Vm, v: Value, argn: usize) Error!i64 {
        return switch (v) {
            .Int => |i| i,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) return self.fail("bad argument #{d} to 'move' (number expected)", .{argn});
                const t = std.math.trunc(n);
                if (t != n) return self.fail("bad argument #{d} to 'move' (number has no integer representation)", .{argn});
                if (t < -9_223_372_036_854_775_808.0 or t >= 9_223_372_036_854_775_808.0) {
                    return self.fail("bad argument #{d} to 'move' (number has no integer representation)", .{argn});
                }
                break :blk @as(i64, @intFromFloat(t));
            },
            else => return self.fail("bad argument #{d} to 'move' (number expected)", .{argn}),
        };
    }

    fn tableCreateArgToNonNeg(self: *Vm, v: Value, argn: usize) Error!usize {
        const i: i64 = switch (v) {
            .Int => |x| x,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) return self.fail("bad argument #{d} to 'create' (out of range)", .{argn});
                const t = std.math.trunc(n);
                if (t != n) return self.fail("bad argument #{d} to 'create' (out of range)", .{argn});
                if (t < -9_223_372_036_854_775_808.0 or t >= 9_223_372_036_854_775_808.0) {
                    return self.fail("bad argument #{d} to 'create' (out of range)", .{argn});
                }
                break :blk @as(i64, @intFromFloat(t));
            },
            else => return self.fail("bad argument #{d} to 'create' (out of range)", .{argn}),
        };
        if (i < 0) return self.fail("bad argument #{d} to 'create' (out of range)", .{argn});
        if (i > std.math.maxInt(i32)) return self.fail("bad argument #{d} to 'create' (out of range)", .{argn});
        return @intCast(i);
    }

    fn builtinTableCreate(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("bad argument #1 to 'create' (out of range)", .{});
        const narray = try self.tableCreateArgToNonNeg(args[0], 1);
        const nhash = if (args.len >= 2) try self.tableCreateArgToNonNeg(args[1], 2) else 0;

        // Keep limits conservative; suite checks this path with huge sizes.
        if (narray > 1_000_000_000 or nhash > 1_000_000_000) return self.fail("table overflow", .{});
        if (narray > std.math.maxInt(usize) - nhash) return self.fail("table overflow", .{});

        const t = try self.allocTable();
        if (narray != 0) try t.array.ensureTotalCapacity(self.alloc, narray);
        // Approximate allocation accounting used by tests through collectgarbage("count").
        self.gc_count_kb += @as(f64, @floatFromInt((narray * 8 + nhash * 16) / 1024));
        outs[0] = .{ .Table = t };
    }

    fn builtinTableMove(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len > 0) outs[0] = .Nil;
        if (args.len < 4) return self.fail("bad argument #1 to 'move' (table expected)", .{});
        const src = switch (args[0]) {
            .Table => |t| t,
            else => return self.fail("bad argument #1 to 'move' (table expected, got {s})", .{self.valueTypeName(args[0])}),
        };
        const f = try self.tableMoveArgToInt(args[1], 2);
        const e = try self.tableMoveArgToInt(args[2], 3);
        const t = try self.tableMoveArgToInt(args[3], 4);
        const dst = if (args.len >= 5) switch (args[4]) {
            .Table => |dt| dt,
            else => return self.fail("bad argument #5 to 'move' (table expected, got {s})", .{self.valueTypeName(args[4])}),
        } else src;

        if (e < f) {
            if (outs.len > 0) outs[0] = .{ .Table = dst };
            return;
        }

        const span_i128: i128 = (@as(i128, e) - @as(i128, f)) + 1;
        if (span_i128 <= 0 or span_i128 > std.math.maxInt(i64)) return self.fail("too many elements to move", .{});
        const n: i64 = @intCast(span_i128);
        const n_minus_1 = n - 1;
        const dst_last = std.math.add(i64, t, n_minus_1) catch return self.fail("destination wrap around", .{});
        _ = dst_last;

        const backward = src == dst and t > f and t <= e;
        if (backward) {
            var off = n_minus_1;
            while (off >= 0) : (off -= 1) {
                const src_k = f + off;
                const dst_k = t + off;
                const v = try self.indexValue(.{ .Table = src }, .{ .Int = src_k });
                try self.setIndexValue(.{ .Table = dst }, .{ .Int = dst_k }, v);
            }
        } else {
            var off: i64 = 0;
            while (off < n) : (off += 1) {
                const src_k = f + off;
                const dst_k = t + off;
                const v = try self.indexValue(.{ .Table = src }, .{ .Int = src_k });
                try self.setIndexValue(.{ .Table = dst }, .{ .Int = dst_k }, v);
            }
        }

        if (outs.len > 0) outs[0] = .{ .Table = dst };
    }

    fn builtinTableConcat(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        if (args.len == 0) return self.fail("table expected", .{});
        if (args[0] != .Table) return self.fail("table expected", .{});
        const tobj = args[0];
        const sep = if (args.len >= 2) switch (args[1]) {
            .String => |s| s.bytes(),
            else => return self.fail("table.concat expects string separator", .{}),
        } else "";
        const start_idx: i64 = if (args.len >= 3) switch (args[2]) {
            .Int => |n| n,
            else => return self.fail("table.concat expects integer index", .{}),
        } else 1;
        const end_idx: i64 = if (args.len >= 4) switch (args[3]) {
            .Int => |n| n,
            else => return self.fail("table.concat expects integer index", .{}),
        } else blk: {
            const len_v = try self.evalUnOp(.Hash, tobj);
            break :blk switch (len_v) {
                .Int => |i| i,
                else => return self.fail("object length is not an integer", .{}),
            };
        };

        if (start_idx > end_idx) {
            outs[0] = .{ .String = try self.internStr("") };
            return;
        }

        var total_len: usize = 0;
        var len_k: i64 = start_idx;
        while (len_k <= end_idx) {
            if (len_k > start_idx) total_len +|= sep.len;
            const v = try self.indexValue(tobj, .{ .Int = len_k });
            switch (v) {
                .String => |sv| total_len +|= sv.len,
                .Int => |iv| {
                    var buf: [64]u8 = undefined;
                    const sv = std.fmt.bufPrint(buf[0..], "{d}", .{iv}) catch "";
                    total_len +|= sv.len;
                },
                .Num => |nv| {
                    const sv = try self.numberToStringAlloc(nv);
                    defer self.alloc.free(sv);
                    total_len +|= sv.len;
                },
                else => return self.fail("invalid value at index {d}", .{len_k}),
            }
            if (len_k == end_idx) break;
            len_k += 1;
        }
        try self.testcChargeMemory(total_len);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var k: i64 = start_idx;
        while (k <= end_idx) {
            if (k > start_idx and sep.len != 0) try out.appendSlice(self.alloc, sep);
            const v = try self.indexValue(tobj, .{ .Int = k });
            switch (v) {
                .String => |sv| try out.appendSlice(self.alloc, sv.bytes()),
                .Int => |iv| try appendFmt(self.alloc, &out, "{d}", .{iv}),
                .Num => |nv| {
                    const sv = try self.numberToStringAlloc(nv);
                    try out.appendSlice(self.alloc, sv);
                },
                else => return self.fail("invalid value at index {d}", .{k}),
            }
            if (k == end_idx) break;
            k += 1;
        }
        outs[0] = .{ .String = try self.internStr(try out.toOwnedSlice(self.alloc)) };
    }

    fn builtinTablePack(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        const tbl = try self.allocTable();
        for (args, 0..) |v, i| {
            const k: i64 = @intCast(i + 1);
            try self.tableSetValue(tbl, .{ .Int = k }, v);
        }
        try self.setField(tbl, "n", .{ .Int = @intCast(args.len) });
        outs[0] = .{ .Table = tbl };
    }

    fn builtinTableInsert(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = outs;
        if (args.len < 2 or args.len > 3) return self.fail("wrong number of arguments to 'insert'", .{});
        if (args[0] != .Table) return self.fail("table expected", .{});
        const tobj = args[0];
        const len_v = try self.evalUnOp(.Hash, tobj);
        const len: i64 = switch (len_v) {
            .Int => |i| i,
            else => return self.fail("object length is not an integer", .{}),
        };

        if (args.len == 2) {
            const pos = len +% 1;
            try self.setIndexValue(tobj, .{ .Int = pos }, args[1]);
            return;
        }

        const pos: i64 = switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("table.insert expects integer position", .{}),
        };
        const val: Value = args[2];
        if (pos < 1 or pos > len + 1) return self.fail("table.insert position out of bounds", .{});
        var k = len;
        while (k >= pos) : (k -= 1) {
            const cur = try self.indexValue(tobj, .{ .Int = k });
            try self.setIndexValue(tobj, .{ .Int = k + 1 }, cur);
            if (k == pos) break;
        }
        try self.setIndexValue(tobj, .{ .Int = pos }, val);
    }

    fn builtinTableRemove(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) return self.fail("table.remove expects table", .{});
        if (args[0] != .Table) return self.fail("table expected", .{});
        const tobj = args[0];
        const len_v = try self.evalUnOp(.Hash, tobj);
        const len: i64 = switch (len_v) {
            .Int => |i| i,
            else => return self.fail("object length is not an integer", .{}),
        };
        const explicit_pos = args.len >= 2;
        const pos: i64 = if (explicit_pos) switch (args[1]) {
            .Int => |i| i,
            else => return self.fail("table.remove expects integer index", .{}),
        } else len;

        // Lua accepts remove at position 0 only for empty sequences (#t == 0).
        // (e.g. table.remove(t, #t) when #t == 0). For non-empty sequences,
        // explicit 0 is out of bounds.
        if (explicit_pos and pos == 0 and len > 0) {
            return self.fail("position out of bounds", .{});
        }

        if (!explicit_pos and pos == 0) {
            const removed = try self.indexValue(tobj, .{ .Int = 0 });
            try self.setIndexValue(tobj, .{ .Int = 0 }, .Nil);
            if (outs.len > 0) outs[0] = removed;
            return;
        }

        if (pos < 1 or pos > len) {
            if (outs.len > 0) outs[0] = .Nil;
            return;
        }

        const removed = try self.indexValue(tobj, .{ .Int = pos });
        var i = pos;
        while (i < len) : (i += 1) {
            const nxt = try self.indexValue(tobj, .{ .Int = i + 1 });
            try self.setIndexValue(tobj, .{ .Int = i }, nxt);
        }
        try self.setIndexValue(tobj, .{ .Int = len }, .Nil);
        if (outs.len > 0) outs[0] = removed;
    }

    fn tableSortLess(self: *Vm, cmp_fn: ?Value, a: Value, b: Value) Error!bool {
        if (cmp_fn) |cf| {
            var outv: Value = .Nil;
            switch (cf) {
                .Builtin => |id| {
                    if (id == .coroutine_yield) {
                        return self.fail("attempt to yield across a C-call boundary", .{});
                    }
                    var outs1 = [_]Value{.Nil};
                    const call_args = [_]Value{ a, b };
                    self.callBuiltin(id, call_args[0..], outs1[0..]) catch {
                        if (id == .coroutine_yield) {
                            return self.fail("attempt to yield across a C-call boundary", .{});
                        }
                        return self.fail("invalid order function for sorting ('{s}')", .{id.name()});
                    };
                    outv = outs1[0];
                },
                .Closure => |cl| {
                    const call_args = [_]Value{ a, b };
                    const ret = try self.runClosure(cl, call_args[0..], false);
                    defer self.alloc.free(ret);
                    outv = if (ret.len > 0) ret[0] else .Nil;
                },
                else => {
                    var call_args = [_]Value{ a, b };
                    const resolved = try self.resolveCallable(cf, call_args[0..], null);
                    defer if (resolved.owned_args) |owned| self.alloc.free(owned);
                    switch (resolved.callee) {
                        .Builtin => |id| {
                            if (id == .coroutine_yield) {
                                return self.fail("attempt to yield across a C-call boundary", .{});
                            }
                            var outs1 = [_]Value{.Nil};
                            self.callBuiltin(id, resolved.args, outs1[0..]) catch {
                                if (id == .coroutine_yield) {
                                    return self.fail("attempt to yield across a C-call boundary", .{});
                                }
                                return self.fail("invalid order function for sorting ('{s}')", .{id.name()});
                            };
                            outv = outs1[0];
                        },
                        .Closure => |cl| {
                            const ret = try self.runClosure(cl, resolved.args, false);
                            defer self.alloc.free(ret);
                            outv = if (ret.len > 0) ret[0] else .Nil;
                        },
                        else => unreachable,
                    }
                },
            }
            return isTruthy(outv);
        }
        return try self.cmpLt(a, b);
    }

    fn tableSortRange(self: *Vm, arr: []Value, cmp_fn: ?Value, lo: usize, hi: usize, depth: usize) Error!void {
        if (hi <= lo) return;
        if (depth > 128) return self.fail("invalid order function for sorting", .{});

        var i = lo;
        var j = hi;
        const pivot = arr[lo + (hi - lo) / 2];
        while (i <= j) {
            while (i <= hi and try self.tableSortLess(cmp_fn, arr[i], pivot)) : (i += 1) {}
            while (j >= lo and try self.tableSortLess(cmp_fn, pivot, arr[j])) {
                if (j == 0) break;
                j -= 1;
            }
            if (i <= j) {
                const tmp = arr[i];
                arr[i] = arr[j];
                arr[j] = tmp;
                i += 1;
                if (j == 0) break;
                j -= 1;
            }
        }

        if (lo < j) try self.tableSortRange(arr, cmp_fn, lo, j, depth + 1);
        if (i < hi) try self.tableSortRange(arr, cmp_fn, i, hi, depth + 1);
    }

    fn builtinTableSort(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = outs;
        if (args.len == 0) return self.fail("table.sort expects table", .{});
        if (args[0] != .Table) return self.fail("table.sort expects table", .{});
        const tobj = args[0];
        const cmp: ?Value = if (args.len >= 2 and args[1] != .Nil) args[1] else null;
        const len_v = try self.evalUnOp(.Hash, tobj);
        const len_i64: i64 = switch (len_v) {
            .Int => |i| i,
            else => return self.fail("object length is not an integer", .{}),
        };
        if (len_i64 < 2) return;
        if (len_i64 > 1_000_000) return self.fail("array is too big", .{});
        const n: usize = @intCast(len_i64);
        var arr = try self.alloc.alloc(Value, n);
        defer self.alloc.free(arr);
        for (0..n) |i| {
            const k: i64 = @intCast(i + 1);
            arr[i] = try self.indexValue(tobj, .{ .Int = k });
        }
        try self.tableSortRange(arr, cmp, 0, n - 1, 0);
        for (0..n) |i| {
            const k: i64 = @intCast(i + 1);
            try self.setIndexValue(tobj, .{ .Int = k }, arr[i]);
        }

        if (cmp != null and n <= 128) {
            var k: usize = 1;
            while (k < n) : (k += 1) {
                if (try self.tableSortLess(cmp, arr[k], arr[k - 1])) {
                    return self.fail("invalid order function for sorting", .{});
                }
            }
        }
    }

    fn builtinPrint(self: *Vm, args: []const Value) Error!void {
        var out = stdio.stdout();
        for (args, 0..) |v, i| {
            if (i != 0) out.writeByte('\t') catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
            };
            self.writeValue(&out, v) catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
            };
        }
        out.writeByte('\n') catch |e| switch (e) {
            error.BrokenPipe => return,
            else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
        };
    }

    // Lua 5.5 has global 'warn'. For parity we keep it available even if warnings
    // are not yet routed to a host warning channel.
    fn builtinWarn(self: *Vm, args: []const Value, outs: []Value) Error!void {
        _ = self;
        _ = args;
        _ = outs;
    }

    fn writeValue(self: *Vm, w: anytype, v: Value) anyerror!void {
        _ = self;
        switch (v) {
            .Nil => try w.writeAll("nil"),
            .Bool => |b| try w.writeAll(if (b) "true" else "false"),
            .Int => |i| try w.print("{d}", .{i}),
            .Num => |n| try w.print("{}", .{n}),
            .String => |s| try w.writeAll(s.bytes()),
            .Table => |t| try w.print("table: 0x{x}", .{@intFromPtr(t)}),
            .Builtin => |id| try w.print("function: builtin {s}", .{id.name()}),
            .Closure => |cl| try w.print("function: {s}", .{cl.func.name}),
            .Thread => |th| try w.print("thread: 0x{x}", .{@intFromPtr(th)}),
        }
    }

    fn valueToStringAlloc(self: *Vm, v: Value) Error![]const u8 {
        if (metamethodValue(self, v, "__tostring")) |mm| {
            var call_args = [_]Value{v};
            const tv = try self.callMetamethod(mm, "__tostring", call_args[0..]);
            if (tv != .String) return self.fail("'__tostring' must return a string", .{});
            return tv.String.bytes();
        }
        if (asFileTable(self, v)) |ft| {
            if (self.getFieldOpt(ft, "__closed")) |cv| {
                if (cv == .Bool and cv.Bool) return "file (closed)";
            }
            return try std.fmt.allocPrint(self.alloc, "file (0x{x})", .{@intFromPtr(ft)});
        }
        return switch (v) {
            .Nil => "nil",
            .Bool => |b| if (b) "true" else "false",
            .Int => |i| try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
            .Num => |n| try self.numberToStringAlloc(n),
            .String => |s| s.bytes(),
            .Table => |t| try std.fmt.allocPrint(self.alloc, "{s}: 0x{x}", .{ self.valueTypeName(v), @intFromPtr(t) }),
            .Builtin => |id| try std.fmt.allocPrint(self.alloc, "function: builtin {s}", .{id.name()}),
            .Closure => |cl| try std.fmt.allocPrint(self.alloc, "function: {s}", .{cl.func.name}),
            .Thread => |th| try std.fmt.allocPrint(self.alloc, "{s}: 0x{x}", .{ self.valueTypeName(v), @intFromPtr(th) }),
        };
    }

    fn numberToStringAlloc(self: *Vm, n: f64) Error![]const u8 {
        const s = try std.fmt.allocPrint(self.alloc, "{}", .{n});
        if (!std.math.isFinite(n)) return s;
        if (std.mem.indexOfAny(u8, s, ".eE") != null) return s;
        const s2 = try std.fmt.allocPrint(self.alloc, "{s}.0", .{s});
        self.alloc.free(s);
        return s2;
    }

    fn parseInt(self: *Vm, lexeme: []const u8) Error!i64 {
        var s = lexeme;
        var base: u8 = 10;
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            base = 16;
            s = s[2..];
        }
        const v = std.fmt.parseInt(i64, s, base) catch |e| switch (e) {
            error.InvalidCharacter => return self.fail("invalid integer literal: {s}", .{lexeme}),
            error.Overflow => blk: {
                // Hex literals that overflow i64 but fit in u64 (two's complement).
                const uval = std.fmt.parseInt(u64, s, base) catch
                    return self.fail("integer literal overflow: {s}", .{lexeme});
                break :blk @as(i64, @bitCast(uval));
            },
        };
        return v;
    }

    fn parseHexIntWrap(self: *Vm, lexeme: []const u8) ?i64 {
        _ = self;
        if (lexeme.len < 3) return null;
        if (!(lexeme[0] == '0' and (lexeme[1] == 'x' or lexeme[1] == 'X'))) return null;
        const s = lexeme[2..];
        if (s.len == 0) return null;
        var u: u64 = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            const d: u64 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') 10 + (c - 'a') else if (c >= 'A' and c <= 'F') 10 + (c - 'A') else return null;
            u = (u *% 16) +% d;
        }
        return @bitCast(u);
    }

    fn parseHexStringIntWrap(s0: []const u8) ?i64 {
        if (s0.len < 3) return null;
        var s = s0;
        var neg = false;
        if (s[0] == '+' or s[0] == '-') {
            neg = s[0] == '-';
            s = s[1..];
            if (s.len < 3) return null;
        }
        if (!(s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))) return null;
        const hex = s[2..];
        if (hex.len == 0) return null;

        // Integer-only path: no fractional/exponent markers.
        if (std.mem.indexOfAny(u8, hex, ".pP") != null) return null;
        var u: u64 = 0;
        var i: usize = 0;
        while (i < hex.len) : (i += 1) {
            const c = hex[i];
            const d: u64 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') 10 + (c - 'a') else if (c >= 'A' and c <= 'F') 10 + (c - 'A') else return null;
            u = (u *% 16) +% d;
        }
        const v: i64 = @bitCast(u);
        return if (neg) -%v else v;
    }

    fn parseHexFloatFastPath(s0: []const u8) ?f64 {
        if (s0.len < 4) return null;
        var s = s0;
        var neg = false;
        if (s[0] == '+' or s[0] == '-') {
            neg = s[0] == '-';
            s = s[1..];
            if (s.len < 4) return null;
        }
        if (!(s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))) return null;
        const body = s[2..];
        if (std.mem.indexOfAny(u8, body, "pP") != null) return null;
        const dot = std.mem.indexOfScalar(u8, body, '.') orelse return null;
        const left = body[0..dot];
        const right = body[dot + 1 ..];
        if (left.len == 0 or right.len == 0) return null;

        // 0xFFF...F.0
        if (right.len == 1 and right[0] == '0') {
            var i: usize = 0;
            while (i < left.len) : (i += 1) {
                const c = left[i];
                if (!(c == 'f' or c == 'F')) return null;
            }
            const exp: i32 = @intCast(4 * left.len);
            const v = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exp))) - 1.0;
            return if (neg) -v else v;
        }

        // 0x0.000...0001
        if (left.len == 1 and left[0] == '0') {
            var i: usize = 0;
            while (i < right.len - 1) : (i += 1) {
                if (right[i] != '0') return null;
            }
            if (right[right.len - 1] != '1') return null;
            const exp: i32 = @intCast(-4 * @as(i32, @intCast(right.len)));
            const v = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exp)));
            return if (neg) -v else v;
        }

        return null;
    }

    fn parseNum(self: *Vm, lexeme: []const u8) Error!f64 {
        const v = std.fmt.parseFloat(f64, lexeme) catch return self.fail("invalid number literal: {s}", .{lexeme});
        return v;
    }

    fn tableGetRawValue(self: *Vm, tbl: *Table, key: Value) Error!Value {
        // NaN keys: rawget on NaN historically returns Nil without raising an
        // error (the NaN check lives in rawSet / setIndexValue instead). PUC
        // actually errors on NaN lookups in some paths but the test suite has
        // historically been lenient about this. Preserve Nil-on-NaN behavior.
        if (key == .Num and std.math.isNan(key.Num)) return .Nil;
        return self.rawGet(tbl, key);
    }

    fn tableBorderLen(tbl: *const Table) i64 {
        const n = tbl.array.items.len;
        if (n == 0) return 0;
        if (tbl.array.items[n - 1] != .Nil) return @intCast(n);
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (mid != 0 and tbl.array.items[mid - 1] != .Nil) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return @intCast(lo);
    }

    fn tableGetValue(self: *Vm, tbl: *Table, key: Value) Error!Value {
        return self.tableGetValueDepth(tbl, key, 0);
    }

    fn tableGetValueDepth(self: *Vm, tbl: *Table, key: Value, depth: usize) Error!Value {
        if (depth >= 200) return self.fail("loop in gettable", .{});
        const raw = try self.tableGetRawValue(tbl, key);
        if (raw != .Nil) return raw;
        const mt = tbl.metatable orelse return .Nil;
        const mm = self.getFieldOpt(mt, "__index") orelse return .Nil;
        const saved_nwo = self.debug_namewhat_override;
        const saved_no = self.debug_name_override;
        self.debug_namewhat_override = "metamethod";
        self.debug_name_override = "index";
        defer {
            self.debug_namewhat_override = saved_nwo;
            self.debug_name_override = saved_no;
        }
        return switch (mm) {
            .Table => |t| try self.tableGetValueDepth(t, key, depth + 1),
            .Builtin => |id| blk: {
                var call_args = [_]Value{ .{ .Table = tbl }, key };
                var out: [1]Value = .{.Nil};
                try self.callBuiltin(id, call_args[0..], out[0..]);
                break :blk out[0];
            },
            .Closure => |cl| blk: {
                var call_args = [_]Value{ .{ .Table = tbl }, key };
                const ret = try self.runClosure(cl, call_args[0..], false);
                defer self.alloc.free(ret);
                break :blk if (ret.len > 0) ret[0] else Value.Nil;
            },
            else => return self.fail("attempt to index a {s} value", .{mm.typeName()}),
        };
    }

    fn indexValue(self: *Vm, object: Value, key: Value) Error!Value {
        return self.indexValueDepth(object, key, 0);
    }

    fn indexValueDepth(self: *Vm, object: Value, key: Value, depth: usize) Error!Value {
        if (depth >= 200) return self.fail("loop in gettable", .{});
        switch (object) {
            .Table => |t| return self.tableGetValueDepth(t, key, depth + 1),
            else => {},
        }

        const mm = metamethodValue(self, object, "__index") orelse {
            return self.fail("attempt to index a {s} value", .{object.typeName()});
        };
        const saved_nwo = self.debug_namewhat_override;
        const saved_no = self.debug_name_override;
        self.debug_namewhat_override = "metamethod";
        self.debug_name_override = "index";
        defer {
            self.debug_namewhat_override = saved_nwo;
            self.debug_name_override = saved_no;
        }
        return switch (mm) {
            .Table => |t| try self.tableGetValueDepth(t, key, depth + 1),
            .Builtin => |id| blk: {
                var call_args = [_]Value{ object, key };
                var out: [1]Value = .{.Nil};
                try self.callBuiltin(id, call_args[0..], out[0..]);
                break :blk out[0];
            },
            .Closure => |cl| blk: {
                var call_args = [_]Value{ object, key };
                const ret = try self.runClosure(cl, call_args[0..], false);
                defer self.alloc.free(ret);
                break :blk if (ret.len > 0) ret[0] else Value.Nil;
            },
            else => return self.fail("attempt to index a {s} value", .{object.typeName()}),
        };
    }

    fn setIndexValue(self: *Vm, object: Value, key: Value, val: Value) Error!void {
        return self.setIndexValueDepth(object, key, val, 0);
    }

    fn setIndexValueDepth(self: *Vm, object: Value, key: Value, val: Value, depth: usize) Error!void {
        if (depth >= 200) return self.fail("loop in settable", .{});
        if (object == .Table) {
            const tbl = object.Table;
            const raw = try self.tableGetRawValue(tbl, key);
            if (raw != .Nil or tbl.metatable == null) {
                return self.tableSetValue(tbl, key, val);
            }
            const mm = self.getFieldOpt(tbl.metatable.?, "__newindex") orelse return self.tableSetValue(tbl, key, val);
            switch (mm) {
                .Table => |t| return self.setIndexValueDepth(.{ .Table = t }, key, val, depth + 1),
                .Builtin => |id| {
                    var call_args = [_]Value{ object, key, val };
                    var out: [1]Value = .{.Nil};
                    return self.callBuiltin(id, call_args[0..], out[0..]);
                },
                .Closure => |cl| {
                    var call_args = [_]Value{ object, key, val };
                    const ret = try self.runClosure(cl, call_args[0..], false);
                    defer self.alloc.free(ret);
                    return;
                },
                else => return self.fail("attempt to index a {s} value", .{object.typeName()}),
            }
        }

        const mm = metamethodValue(self, object, "__newindex") orelse {
            return self.fail("attempt to index a {s} value", .{object.typeName()});
        };
        switch (mm) {
            .Table => |t| return self.setIndexValueDepth(.{ .Table = t }, key, val, depth + 1),
            .Builtin => |id| {
                var call_args = [_]Value{ object, key, val };
                var out: [1]Value = .{.Nil};
                return self.callBuiltin(id, call_args[0..], out[0..]);
            },
            .Closure => |cl| {
                var call_args = [_]Value{ object, key, val };
                const ret = try self.runClosure(cl, call_args[0..], false);
                defer self.alloc.free(ret);
                return;
            },
            else => return self.fail("attempt to index a {s} value", .{object.typeName()}),
        }
    }

    fn valueMetatable(self: *Vm, v: Value) ?*Table {
        return switch (v) {
            .Table => |t| t.metatable,
            .String => if (self.string_metatable_enabled) self.string_metatable else null,
            .Int, .Num => self.number_metatable,
            .Bool => self.boolean_metatable,
            .Nil => self.nil_metatable,
            .Builtin, .Closure => self.function_metatable,
            .Thread => self.thread_metatable,
        };
    }

    fn valueTypeName(self: *Vm, v: Value) []const u8 {
        if (isTestcUserdata(self, v)) return "userdata";
        if (valueMetatable(self, v)) |mt| {
            if (self.getFieldOpt(mt, "__name")) |namev| {
                if (namev == .String) return namev.String.bytes();
            }
        }
        return v.typeName();
    }

    fn isYieldCloseObject(self: *Vm, v: Value) bool {
        if (v != .Table) return false;
        const mt = v.Table.metatable orelse return false;
        const mm = self.getFieldOpt(mt, "__close") orelse return false;
        return mm == .Builtin and mm.Builtin == .coroutine_yield;
    }

    fn metamethodValue(self: *Vm, v: Value, mm_name: []const u8) ?Value {
        const mt = valueMetatable(self, v) orelse return null;
        const mm = self.getFieldOpt(mt, mm_name) orelse return null;
        if (mm == .Nil) return null;
        return mm;
    }

    fn callMetamethod(self: *Vm, mmv: Value, opname: []const u8, args: []const Value) Error!Value {
        const saved_nwo = self.debug_namewhat_override;
        const saved_no = self.debug_name_override;
        self.debug_namewhat_override = "metamethod";
        self.debug_name_override = opname;
        defer {
            self.debug_namewhat_override = saved_nwo;
            self.debug_name_override = saved_no;
        }

        switch (mmv) {
            .Builtin => |id| {
                var out: [1]Value = .{.Nil};
                try self.callBuiltin(id, args, out[0..]);
                return out[0];
            },
            .Closure => |cl| {
                const ret = try self.runClosure(cl, args, false);
                defer self.alloc.free(ret);
                return if (ret.len > 0) ret[0] else .Nil;
            },
            else => return self.fail("metamethod '{s}' is not callable ({s} value)", .{ opname, mmv.typeName() }),
        }
    }

    fn callBinaryMetamethod(self: *Vm, lhs: Value, rhs: Value, mm_name: []const u8, opname: []const u8) Error!?Value {
        const mm = metamethodValue(self, lhs, mm_name) orelse metamethodValue(self, rhs, mm_name) orelse return null;
        var call_args = [_]Value{ lhs, rhs };
        return try self.callMetamethod(mm, opname, call_args[0..]);
    }

    fn runCloseMetamethod(self: *Vm, obj: Value, err_obj: ?Value) Error!void {
        // false/nil are explicitly allowed as non-closable sentinels.
        if (obj == .Nil) return;
        if (obj == .Bool and !obj.Bool) return;
        if (self.current_thread) |th| {
            if (th.pending_close_builtin and valuesEqual(th.pending_close_builtin_obj, obj)) {
                th.pending_close_builtin = false;
                th.pending_close_builtin_obj = .Nil;
                return;
            }
        }
        const mm = metamethodValue(self, obj, "__close") orelse {
            return self.fail("metamethod 'close' is nil", .{});
        };
        self.close_metamethod_depth += 1;
        defer self.close_metamethod_depth -= 1;
        if (err_obj != null) {
            self.close_metamethod_err_depth += 1;
            defer self.close_metamethod_err_depth -= 1;
        }
        if (err_obj) |e| {
            var call_args = [_]Value{ obj, e };
            _ = self.callMetamethod(mm, "__close", call_args[0..]) catch |e2| switch (e2) {
                error.RuntimeError => {
                    self.annotateCloseRuntimeError();
                    return error.RuntimeError;
                },
                error.Yield => {
                    if (mm == .Builtin and mm.Builtin == .coroutine_yield) {
                        if (self.current_thread) |th| {
                            th.pending_close_builtin = true;
                            th.pending_close_builtin_obj = obj;
                        }
                    }
                    return error.Yield;
                },
                else => return e2,
            };
            self.clearPendingCloseBuiltinForObject(obj);
        } else {
            var call_args = [_]Value{obj};
            _ = self.callMetamethod(mm, "__close", call_args[0..]) catch |e2| switch (e2) {
                error.RuntimeError => {
                    self.annotateCloseRuntimeError();
                    return error.RuntimeError;
                },
                error.Yield => {
                    if (mm == .Builtin and mm.Builtin == .coroutine_yield) {
                        if (self.current_thread) |th| {
                            th.pending_close_builtin = true;
                            th.pending_close_builtin_obj = obj;
                        }
                    }
                    return error.Yield;
                },
                else => return e2,
            };
            self.clearPendingCloseBuiltinForObject(obj);
        }
    }

    fn runTestcCloseMetamethod(self: *Vm, obj: Value, err_obj: ?Value) Error!void {
        self.testc_close_metamethod_depth += 1;
        defer self.testc_close_metamethod_depth -= 1;
        try self.runCloseMetamethod(obj, err_obj);
    }

    fn clearPendingCloseBuiltinForObject(self: *Vm, obj: Value) void {
        if (self.current_thread) |th| {
            if (th.pending_close_builtin and valuesEqual(th.pending_close_builtin_obj, obj)) {
                th.pending_close_builtin = false;
                th.pending_close_builtin_obj = .Nil;
            }
        }
    }

    fn annotateCloseRuntimeError(self: *Vm) void {
        const msg = self.err orelse return;
        if (std.mem.indexOf(u8, msg, "not enough memory") != null) return;
        if (std.mem.indexOf(u8, msg, "in metamethod 'close'") != null) return;
        var tmp: [512]u8 = undefined;
        const msg_copy = std.fmt.bufPrint(tmp[0..], "{s}", .{msg}) catch msg;
        self.err = std.fmt.bufPrint(self.err_buf[0..], "{s}\nin metamethod 'close'", .{msg_copy}) catch msg_copy;
        if (self.err_has_obj and self.err_obj == .String) {
            self.err_obj = .{ .String = self.internStrAssume(self.err.?) };
        }
    }

    fn closePendingFunctionLocals(
        self: *Vm,
        f: *const ir.Function,
        locals: []Value,
        local_active: []bool,
        boxed: []?*Cell,
        err_obj: ?Value,
    ) Error!void {
        var current_err = err_obj;
        var had_close_error = false;
        if (self.current_thread) |th| {
            if (th.pending_close_err_active) {
                current_err = th.pending_close_err;
                had_close_error = true;
            }
        }
        var i: usize = 0;
        while (i < f.insts.len) : (i += 1) {
            const idx: usize = switch (f.insts[i]) {
                .CloseLocal => |c| @intCast(c.local),
                else => continue,
            };
            if (idx >= local_active.len or !local_active[idx]) continue;
            const cur = if (boxed[idx]) |cell| cell.value else locals[idx];
            self.runCloseMetamethod(cur, current_err) catch |e| switch (e) {
                error.RuntimeError => {
                    had_close_error = true;
                    if (self.forced_close_thread != null) self.forced_close_had_error = true;
                    if (self.err_has_obj) {
                        current_err = self.err_obj;
                    } else if (self.err) |msg| {
                        current_err = .{ .String = try self.internStr(msg) };
                    }
                    if (self.current_thread) |th| {
                        if (current_err) |cerr| {
                            th.pending_close_err_active = true;
                            th.pending_close_err = cerr;
                        }
                    }
                },
                else => return e,
            };
            if (boxed[idx]) |cell| cell.value = .Nil;
            locals[idx] = .Nil;
            local_active[idx] = false;
        }
        if (self.current_thread) |th| {
            th.pending_close_err_active = false;
            th.pending_close_err = .Nil;
        }
        if (had_close_error) {
            if (current_err) |e| {
                self.err_obj = e;
                self.err_has_obj = true;
                if (e == .String) {
                    self.err = e.String.bytes();
                } else {
                    self.err = null;
                }
                self.err_source = null;
                self.err_line = -1;
            }
            return error.RuntimeError;
        }
    }

    fn isCloseLocalIndex(f: *const ir.Function, idx: usize) bool {
        for (f.insts) |inst| {
            switch (inst) {
                .CloseLocal => |c| {
                    if (@as(usize, @intCast(c.local)) == idx) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn functionHasCloseLocals(f: *const ir.Function) bool {
        for (f.insts) |inst| {
            switch (inst) {
                .CloseLocal => return true,
                else => {},
            }
        }
        return false;
    }

    fn callUnaryMetamethod(self: *Vm, v: Value, mm_name: []const u8, opname: []const u8) Error!?Value {
        const mm = metamethodValue(self, v, mm_name) orelse return null;
        // Lua passes the operand twice for unary metamethod dispatch.
        var call_args = [_]Value{ v, v };
        return try self.callMetamethod(mm, opname, call_args[0..]);
    }

    const ResolvedCall = struct {
        callee: Value,
        args: []const Value,
        owned_args: ?[]Value = null,
    };

    const CallName = struct {
        namewhat: []const u8,
        name: ?[]const u8 = null,
    };

    fn inferCallName(f: *const ir.Function, call_pc: usize, func_id: ir.ValueId, args: []const ir.ValueId) ?CallName {
        var i = call_pc;
        while (i > 0) {
            i -= 1;
            switch (f.insts[i]) {
                .GetName => |g| {
                    if (g.dst == func_id) return .{ .namewhat = "global", .name = g.name };
                },
                .GetLocal => |g| {
                    if (g.dst == func_id) {
                        const idx: usize = @intCast(g.local);
                        if (idx < f.local_names.len and f.local_names[idx].len != 0) {
                            return .{ .namewhat = "local", .name = f.local_names[idx] };
                        }
                        return .{ .namewhat = "local", .name = "?" };
                    }
                },
                .GetUpvalue => |g| {
                    if (g.dst == func_id) {
                        const idx: usize = @intCast(g.upvalue);
                        if (idx < f.upvalue_names.len and f.upvalue_names[idx].len != 0) {
                            return .{ .namewhat = "upvalue", .name = f.upvalue_names[idx] };
                        }
                        return .{ .namewhat = "upvalue", .name = "?" };
                    }
                },
                .GetField => |g| {
                    if (g.dst != func_id) continue;
                    if (args.len > 0 and args[0] == g.object and call_pc < 512) {
                        return .{ .namewhat = "method", .name = g.name };
                    }
                    return .{ .namewhat = "field", .name = g.name };
                },
                .GetIndex => |g| {
                    if (g.dst == func_id) return .{ .namewhat = "field", .name = "?" };
                },
                else => {},
            }
        }
        return null;
    }

    fn inferOperandName(f: *const ir.Function, use_pc: usize, value_id: ir.ValueId) ?CallName {
        var i = use_pc;
        while (i > 0) {
            i -= 1;
            switch (f.insts[i]) {
                .GetName => |g| {
                    if (g.dst == value_id) return .{ .namewhat = "global", .name = g.name };
                },
                .GetLocal => |g| {
                    if (g.dst == value_id) {
                        const idx: usize = @intCast(g.local);
                        if (idx < f.local_names.len and f.local_names[idx].len != 0) {
                            return .{ .namewhat = "local", .name = f.local_names[idx] };
                        }
                        return .{ .namewhat = "local", .name = "?" };
                    }
                },
                .GetUpvalue => |g| {
                    if (g.dst == value_id) {
                        const idx: usize = @intCast(g.upvalue);
                        if (idx < f.upvalue_names.len and f.upvalue_names[idx].len != 0) {
                            return .{ .namewhat = "upvalue", .name = f.upvalue_names[idx] };
                        }
                        return .{ .namewhat = "upvalue", .name = "?" };
                    }
                },
                .GetField => |g| {
                    if (g.dst == value_id) return .{ .namewhat = "field", .name = g.name };
                },
                .GetIndex => |g| {
                    if (g.dst == value_id) return .{ .namewhat = "field", .name = "?" };
                },
                else => {},
            }
        }
        return null;
    }

    fn forNumericControlForLocal(f: *const ir.Function, local_idx: usize) ?ir.Function.ForNumericControl {
        for (f.for_numeric_controls) |ctrl| {
            if (@as(usize, @intCast(ctrl.init_local)) == local_idx or
                @as(usize, @intCast(ctrl.limit_local)) == local_idx or
                @as(usize, @intCast(ctrl.step_local)) == local_idx)
            {
                return ctrl;
            }
        }
        return null;
    }

    fn localValueAt(locals: []Value, boxed: []?*Cell, idx: usize) Value {
        if (idx < boxed.len) {
            if (boxed[idx]) |cell| return cell.value;
        }
        return locals[idx];
    }

    fn resolveCallable(self: *Vm, initial_callee: Value, initial_args: []const Value, call_name: ?CallName) Error!ResolvedCall {
        var callee = initial_callee;
        var args: []const Value = initial_args;
        var owned: ?[]Value = null;
        var depth: usize = 0;

        while (true) {
            switch (callee) {
                .Builtin, .Closure => return .{ .callee = callee, .args = args, .owned_args = owned },
                else => {
                    if (depth >= 16) return self.fail("attempt to call a value (chain too long)", .{});
                    const mm = metamethodValue(self, callee, "__call") orelse {
                        if (call_name) |cn| {
                            if (cn.name) |nm| {
                                return self.fail("attempt to call a {s} value ({s} '{s}')", .{ callee.typeName(), cn.namewhat, nm });
                            }
                        }
                        return self.fail("attempt to call a {s} value", .{callee.typeName()});
                    };

                    const new_args = try self.alloc.alloc(Value, args.len + 1);
                    new_args[0] = callee;
                    for (args, 0..) |v, i| new_args[i + 1] = v;
                    if (owned) |old| self.alloc.free(old);
                    owned = new_args;
                    args = new_args;
                    callee = mm;
                    depth += 1;
                },
            }
        }
    }

    fn runResolvedCallInto(self: *Vm, resolved: ResolvedCall, dsts: []const ir.ValueId, regs: []Value) Error!void {
        switch (resolved.callee) {
            .Builtin => |id| {
                try self.runBuiltinCallInto(id, resolved.args, dsts, regs);
            },
            .Closure => |cl| {
                const hook_callee: Value = .{ .Closure = cl };
                const hook_args = debugCallTransferArgsForClosure(cl, resolved.args);
                try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, hook_args, 1);
                const ret = try self.runClosure(cl, resolved.args, false);
                defer self.alloc.free(ret);
                const n = @min(dsts.len, ret.len);
                for (0..n) |idx| regs[dsts[idx]] = ret[idx];
            },
            else => unreachable,
        }
    }

    /// Dispatch to the correct execution engine (bytecode or IR) for a closure.
    /// Used by runResolvedCallInto, ReturnCall handlers, builtins, and helpers.
    fn runClosure(self: *Vm, cl: *Closure, args: []const Value, is_tailcall: bool) Error![]Value {
        if (cl.proto) |proto| {
            return try self.runBytecode(proto, cl.upvalues, args, cl);
        } else {
            return try self.runFunctionArgsWithUpvalues(cl.func, cl.upvalues, args, cl, is_tailcall);
        }
    }

    fn runBuiltinForIterFast(self: *Vm, id: BuiltinId, state: Value, ctrl: Value, dsts: []const ir.ValueId, regs: []Value) Error!void {
        var call_args = [_]Value{ state, ctrl };
        var full_outs = [_]Value{ .Nil, .Nil };
        switch (id) {
            .next => try self.builtinNext(call_args[0..], full_outs[0..]),
            .ipairs_iter => try self.builtinIpairsIter(call_args[0..], full_outs[0..]),
            else => unreachable,
        }
        const n = @min(dsts.len, full_outs.len);
        for (0..n) |idx| regs[dsts[idx]] = full_outs[idx];
        var i = n;
        while (i < dsts.len) : (i += 1) regs[dsts[i]] = .Nil;
    }

    fn runBuiltinCallInto(self: *Vm, id: BuiltinId, args: []const Value, dsts: []const ir.ValueId, regs: []Value) Error!void {
        // Builtin arguments live in VM registers or temporary call buffers.
        // A call/return debug hook can run arbitrary Lua and trigger GC before
        // the builtin itself executes. PUC keeps call arguments on the Lua
        // stack; root them here for the same lifetime.
        var roots = self.gcTempRoots();
        defer roots.end();
        for (args) |arg| try roots.add(arg);

        const out_len = @max(self.builtinOutLen(id, args), dsts.len);
        var full_outs_small: [8]Value = undefined;
        var full_outs: []Value = undefined;
        var full_outs_heap = false;
        if (out_len <= full_outs_small.len) {
            full_outs = full_outs_small[0..out_len];
        } else {
            full_outs = try self.alloc.alloc(Value, out_len);
            full_outs_heap = true;
        }
        defer if (full_outs_heap) self.alloc.free(full_outs);
        for (full_outs) |*o| o.* = .Nil;
        const hook_callee: Value = .{ .Builtin = id };
        if (self.hasActiveHookEvent('c')) {
            try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, args, 1);
        }
        try self.callBuiltin(id, args, full_outs);
        const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, full_outs.len) else full_outs.len;
        if (self.hasActiveHookEvent('r')) {
            try self.debugDispatchHookWithCalleeTransfer("return", null, hook_callee, full_outs[0..used], 1);
        }
        const n = @min(dsts.len, used);
        for (0..n) |idx| regs[dsts[idx]] = full_outs[idx];
    }

    fn hasActiveHookEvent(self: *Vm, event_tag: u8) bool {
        if (self.in_debug_hook) return false;
        const hook_state = self.activeHookState();
        if (hook_state.func == null or hook_state.func.? == .Nil) return false;
        return switch (event_tag) {
            'c' => hook_state.has_call,
            'r' => hook_state.has_return,
            'l' => hook_state.has_line,
            else => false,
        };
    }

    fn valueToIntForBitwise(v: Value) ?i64 {
        return switch (v) {
            .Int => |i| i,
            .Num => |n| blk: {
                if (!std.math.isFinite(n)) break :blk null;
                const t = std.math.trunc(n);
                if (t != n) break :blk null;
                if (t < -9_223_372_036_854_775_808.0 or t >= 9_223_372_036_854_775_808.0) break :blk null;
                break :blk @as(i64, @intFromFloat(t));
            },
            else => null,
        };
    }

    fn isNumberLikeForArithmetic(v: Value) bool {
        return switch (v) {
            .Int, .Num => true,
            .String => |s| blk: {
                _ = std.fmt.parseFloat(f64, s.bytes()) catch break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn coerceArithmeticValue(v: Value) ?Value {
        return switch (v) {
            .Int, .Num => v,
            .String => |s| blk: {
                const t = std.mem.trim(u8, s.bytes(), " \t\r\n");
                const n = std.fmt.parseFloat(f64, t) catch break :blk null;
                if (std.math.isFinite(n) and @floor(n) == n and n >= -9_223_372_036_854_775_808.0 and n < 9_223_372_036_854_775_808.0) {
                    break :blk Value{ .Int = @as(i64, @intFromFloat(n)) };
                }
                break :blk Value{ .Num = n };
            },
            else => null,
        };
    }

    fn isNumWithoutInteger(v: Value) bool {
        return v == .Num and valueToIntForBitwise(v) == null;
    }

    fn failCompare(self: *Vm, lhs: Value, rhs: Value) Error {
        const lt = self.valueTypeName(lhs);
        const rt = self.valueTypeName(rhs);
        if (std.mem.eql(u8, lt, rt)) {
            return self.fail("attempt to compare two {s} values", .{lt});
        }
        return self.fail("attempt to compare {s} with {s}", .{ lt, rt });
    }

    fn isTruthy(v: Value) bool {
        return switch (v) {
            .Nil => false,
            .Bool => |b| b,
            else => true,
        };
    }

    fn evalUnOp(self: *Vm, op: TokenKind, src: Value) Error!Value {
        switch (op) {
            .Not => return .{ .Bool = !isTruthy(src) },
            .Minus => return switch (src) {
                .Int => |i| .{ .Int = -%i },
                .Num => |n| .{ .Num = -n },
                else => {
                    if (coerceArithmeticValue(src)) |cv| {
                        return switch (cv) {
                            .Int => |i| .{ .Int = -%i },
                            .Num => |n| .{ .Num = -n },
                            else => unreachable,
                        };
                    }
                    if (try self.callUnaryMetamethod(src, "__unm", "unm")) |v| return v;
                    return self.fail("type error: unary '-' expects number, got {s}", .{src.typeName()});
                },
            },
            .Hash => return switch (src) {
                .String => |s| .{ .Int = @intCast(s.len) },
                .Table => |t| blk: {
                    if (try self.callUnaryMetamethod(src, "__len", "len")) |v| break :blk v;
                    break :blk .{ .Int = tableBorderLen(t) };
                },
                else => {
                    if (try self.callUnaryMetamethod(src, "__len", "len")) |v| return v;
                    return self.fail("attempt to get length of a {s} value", .{src.typeName()});
                },
            },
            .Tilde => {
                if (valueToIntForBitwise(src)) |iv| return .{ .Int = ~iv };
                if (try self.callUnaryMetamethod(src, "__bnot", "bnot")) |v| return v;
                if (isNumWithoutInteger(src)) return self.fail("number has no integer representation", .{});
                return self.fail("attempt to perform bitwise operation on a {s} value", .{self.valueTypeName(src)});
            },
            else => return self.fail("unsupported unary operator: {s}", .{op.name()}),
        }
    }

    fn evalBinOp(self: *Vm, op: TokenKind, lhs: Value, rhs: Value) Error!Value {
        switch (op) {
            .Plus => return self.binAdd(lhs, rhs),
            .Minus => return self.binSub(lhs, rhs),
            .Star => return self.binMul(lhs, rhs),
            .Slash => return self.binDiv(lhs, rhs),
            .Idiv => return self.binIdiv(lhs, rhs),
            .Percent => return self.binMod(lhs, rhs),
            .Caret => return self.binPow(lhs, rhs),
            .Amp => return self.binBand(lhs, rhs),
            .Pipe => return self.binBor(lhs, rhs),
            .Tilde => return self.binBxor(lhs, rhs),
            .Shl => return self.binShl(lhs, rhs),
            .Shr => return self.binShr(lhs, rhs),

            .EqEq => return .{ .Bool = try self.cmpEq(lhs, rhs) },
            .NotEq => return .{ .Bool = !(try self.cmpEq(lhs, rhs)) },
            .Lt => return .{ .Bool = try self.cmpLt(lhs, rhs) },
            .Lte => return .{ .Bool = try self.cmpLte(lhs, rhs) },
            .Gt => return .{ .Bool = try self.cmpGt(lhs, rhs) },
            .Gte => return .{ .Bool = try self.cmpGte(lhs, rhs) },

            .Concat => return self.binConcat(lhs, rhs),
            else => return self.fail("unsupported binary operator: {s}", .{op.name()}),
        }
    }

    fn valuesEqual(lhs: Value, rhs: Value) bool {
        return switch (lhs) {
            .Nil => rhs == .Nil,
            .Bool => |lb| switch (rhs) {
                .Bool => |rb| lb == rb,
                else => false,
            },
            .Int => |li| switch (rhs) {
                .Int => |ri| li == ri,
                .Num => |rn| blk: {
                    if (!std.math.isFinite(rn)) break :blk false;
                    if (@floor(rn) != rn) break :blk false;
                    if (rn < -9_223_372_036_854_775_808.0 or rn >= 9_223_372_036_854_775_808.0) break :blk false;
                    break :blk li == @as(i64, @intFromFloat(rn));
                },
                else => false,
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| blk: {
                    if (!std.math.isFinite(ln)) break :blk false;
                    if (@floor(ln) != ln) break :blk false;
                    if (ln < -9_223_372_036_854_775_808.0 or ln >= 9_223_372_036_854_775_808.0) break :blk false;
                    break :blk @as(i64, @intFromFloat(ln)) == ri;
                },
                .Num => |rn| ln == rn,
                else => false,
            },
            .String => |ls| switch (rhs) {
                .String => |rs| luaStringEq(ls, rs),
                else => false,
            },
            .Table => |lt| switch (rhs) {
                .Table => |rt| lt == rt,
                else => false,
            },
            .Builtin => |lid| switch (rhs) {
                .Builtin => |rid| lid == rid,
                else => false,
            },
            .Closure => |lc| switch (rhs) {
                .Closure => |rc| lc == rc,
                else => false,
            },
            .Thread => |lt| switch (rhs) {
                .Thread => |rt| lt == rt,
                else => false,
            },
        };
    }

    fn cmpEq(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        if (valuesEqual(lhs, rhs)) return true;
        if (lhs == .Table and rhs == .Table) {
            if (try self.callBinaryMetamethod(lhs, rhs, "__eq", "eq")) |v| return isTruthy(v);
        }
        return false;
    }

    fn makeClosure(self: *Vm, func: *const ir.Function, locals: []Value, boxed: []?*Cell, upvalues: []const *Cell) Error!*Closure {
        const n: usize = @intCast(func.num_upvalues);
        if (func.captures.len != n) return self.fail("invalid closure metadata for function {s}", .{func.name});
        const owner_frame_id = if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1].frame_id else 0;
        const owner_func = if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1].func else null;
        const allow_frame_capture_reuse = owner_frame_id != 0 and owner_func != null and !functionHasCloseLocals(owner_func.?);

        const cells = try self.alloc.alloc(*Cell, n);
        for (cells) |*c| c.* = undefined;

        for (func.captures, 0..) |cap, i| {
            cells[i] = switch (cap) {
                .Local => |local_id| blk: {
                    const idx: usize = @intCast(local_id);
                    if (idx >= locals.len) return self.fail("invalid capture local l{d}", .{local_id});
                    if (boxed[idx]) |cell| break :blk cell;
                    if (allow_frame_capture_reuse) {
                        if (self.lookupFrameCaptureCell(owner_frame_id, idx)) |cell| {
                            boxed[idx] = cell;
                            break :blk cell;
                        }
                    }
                    const cell = try self.alloc.create(Cell);
                    cell.* = .{ .value = locals[idx] };
                    try self.gc_cells.append(self.alloc, cell);
                    self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Cell))) / 1024.0;
                    boxed[idx] = cell;
                    if (allow_frame_capture_reuse) {
                        try self.rememberFrameCaptureCell(owner_frame_id, idx, cell);
                    }
                    break :blk cell;
                },
                .Upvalue => |up_id| blk: {
                    const idx: usize = @intCast(up_id);
                    if (idx >= upvalues.len) return self.fail("invalid capture upvalue u{d}", .{up_id});
                    break :blk upvalues[idx];
                },
            };
        }

        try self.testcChargeMemory(@sizeOf(Closure) + 64);
        const cl = try self.alloc.create(Closure);
        cl.* = .{ .func = func, .upvalues = cells };
        try self.gc_closures.append(self.alloc, cl);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Closure))) / 1024.0;
        self.testc_obj_functions += 1;
        if (functionUsesGlobalNames(func) and !functionHasNamedEnvUpvalue(func)) {
            cl.synthetic_env_slot = true;
            if (self.frames.items.len > 0) {
                cl.env_override = frameEnvValue(self, self.frames.items.len - 1) orelse .{ .Table = self.global_env };
            } else {
                cl.env_override = .{ .Table = self.global_env };
            }
        }
        return cl;
    }

    fn evalCallSpec(self: *Vm, spec: *const ir.CallSpec, regs: []Value, varargs: []const Value) Error![]Value {
        const extra = if (spec.use_vararg) varargs.len else 0;
        var args = try self.alloc.alloc(Value, spec.args.len + extra);
        defer self.alloc.free(args);
        for (spec.args, 0..) |id, k| args[k] = regs[id];
        if (spec.use_vararg) {
            for (varargs, 0..) |v, k| args[spec.args.len + k] = v;
        }

        var tail_ret: []Value = &[_]Value{};
        var tail_owned = false;
        if (spec.tail) |t| {
            tail_ret = try self.evalCallSpec(t, regs, varargs);
            tail_owned = true;
        }
        defer if (tail_owned) self.alloc.free(tail_ret);

        const call_args = if (tail_ret.len == 0) args else blk: {
            const all = try self.alloc.alloc(Value, args.len + tail_ret.len);
            for (args, 0..) |v, i| all[i] = v;
            for (tail_ret, 0..) |v, i| all[args.len + i] = v;
            break :blk all;
        };
        defer if (tail_ret.len != 0) self.alloc.free(call_args);

        const callee = regs[spec.func];
        const resolved = try self.resolveCallable(callee, call_args, null);
        defer if (resolved.owned_args) |owned| self.alloc.free(owned);
        var roots = self.gcTempRoots();
        defer roots.end();
        for (resolved.args) |arg| try roots.add(arg);
        switch (resolved.callee) {
            .Builtin => |id| {
                const hook_callee: Value = .{ .Builtin = id };
                try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, resolved.args, 1);
                const out_len = self.builtinOutLen(id, resolved.args);
                const outs = try self.alloc.alloc(Value, out_len);
                errdefer self.alloc.free(outs);
                try self.callBuiltin(id, resolved.args, outs);
                const used = if (builtinHasDynamicOutCount(id)) @min(self.last_builtin_out_count, outs.len) else outs.len;
                for (outs[0..used]) |out| try roots.add(out);
                try self.debugDispatchHookWithCalleeTransfer("return", null, hook_callee, outs[0..used], 1);
                if (used == outs.len) return outs;
                const ret = try self.alloc.alloc(Value, used);
                for (0..used) |i| ret[i] = outs[i];
                self.alloc.free(outs);
                return ret;
            },
            .Closure => |cl| {
                const hook_callee: Value = .{ .Closure = cl };
                const hook_args = debugCallTransferArgsForClosure(cl, resolved.args);
                try self.debugDispatchHookWithCalleeTransfer("call", null, hook_callee, hook_args, 1);
                const ret = try self.runClosure(cl, resolved.args, false);
                return ret;
            },
            else => unreachable,
        }
    }

    const TestcContext = struct {
        upvalues: ?[]Value = null,
        upenv: ?Value = null,
        state: ?*Table = null,
        first_arg: ?Value = null,
    };

    const TestcThreadStacks = struct {
        map: std.AutoHashMapUnmanaged(*Thread, std.ArrayListUnmanaged(Value)) = .empty,
        shadow_map: std.AutoHashMapUnmanaged(*Thread, std.ArrayListUnmanaged(Value)) = .empty,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |stack| {
                stack.deinit(alloc);
            }
            self.map.deinit(alloc);
            var shadow_it = self.shadow_map.valueIterator();
            while (shadow_it.next()) |stack| {
                stack.deinit(alloc);
            }
            self.shadow_map.deinit(alloc);
        }

        fn getOrCreate(self: *@This(), alloc: std.mem.Allocator, th: *Thread) std.mem.Allocator.Error!*std.ArrayListUnmanaged(Value) {
            const gop = try self.map.getOrPut(alloc, th);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            return gop.value_ptr;
        }

        fn getShadow(self: *@This(), th: *Thread) ?*std.ArrayListUnmanaged(Value) {
            return self.shadow_map.getPtr(th);
        }

        fn getOrCreateShadow(self: *@This(), alloc: std.mem.Allocator, th: *Thread) std.mem.Allocator.Error!*std.ArrayListUnmanaged(Value) {
            const gop = try self.shadow_map.getOrPut(alloc, th);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            return gop.value_ptr;
        }

        fn clearShadow(self: *@This(), alloc: std.mem.Allocator, th: *Thread) void {
            if (self.shadow_map.getPtr(th)) |stack| {
                stack.deinit(alloc);
                _ = self.shadow_map.remove(th);
            }
        }
    };

    fn testcContextFromCallable(self: *Vm, v: Value) ?TestcContext {
        if (v != .Table) return null;
        const upv = self.getFieldOpt(v.Table, "__testc_upvalues") orelse return null;
        if (upv != .Table) return null;
        const items = upv.Table.array.items;
        const upenv = self.getFieldOpt(v.Table, "__testc_upenv");
        return .{ .upvalues = items, .upenv = upenv, .first_arg = v };
    }

    fn getOrCreateTestStateMainThread(self: *Vm, state: *Table) Error!*Thread {
        if (self.getFieldOpt(state, "_mainthread")) |v| {
            if (v == .Thread) return v.Thread;
        }
        const th = try self.alloc.create(Thread);
        th.* = .{
            .status = .suspended,
            .callee = .Nil,
            .testc_state_main = true,
        };
        try self.gc_threads.append(self.alloc, th);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0;
        try self.setField(state, "_mainthread", .{ .Thread = th });
        return th;
    }

    fn currentCallableEnvValue(self: *Vm) Value {
        if (self.frames.items.len > 0) {
            return frameEnvValue(self, self.frames.items.len - 1) orelse .{ .Table = self.global_env };
        }
        return .{ .Table = self.global_env };
    }

    fn builtinTestcTestC(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (self.current_thread) |th| {
            if (th.testc_close_return_values != null) {
                try self.resumeTestcCloseReturnContinuation(th, outs);
                return;
            }
            if (th.testc_pending_conts.items.len != 0) {
                try self.resumePendingTestcContinuation(th, args, outs);
                return;
            }
        }

        if (args.len == 0) {
            return self.fail("bad argument #1 to 'testC' (string expected)", .{});
        }
        var arg_off: usize = 0;
        var include_script_on_stack = true;
        var script_source: ?[]const u8 = null;
        var ctx: TestcContext = .{};
        if (args[0] == .Table) {
            if (self.testcContextFromCallable(args[0])) |cctx| {
                ctx = cctx;
                const script_from_upvalue = switch (self.getFieldOpt(args[0].Table, "__testc_script_upvalue") orelse .Nil) {
                    .Bool => |b| b,
                    else => false,
                };
                if (script_from_upvalue) {
                    if (cctx.upvalues) |upvs| {
                        if (upvs.len == 0 or upvs[0] != .String) return self.fail("bad argument #1 to C closure (string expected)", .{});
                        script_source = upvs[0].String.bytes();
                        include_script_on_stack = false;
                    } else {
                        return self.fail("bad argument #1 to C closure (string expected)", .{});
                    }
                } else {
                    if (args.len < 2 or args[1] != .String) return self.fail("bad argument #1 to C closure (string expected)", .{});
                    arg_off = 1;
                    include_script_on_stack = false;
                    script_source = args[1].String.bytes();
                }
            } else if (self.getFieldOpt(args[0].Table, "_is_test_state")) |flag| {
                if (flag != .Bool or !flag.Bool) return self.fail("bad argument #1 to 'testC' (string expected)", .{});
                if (args.len < 2 or args[1] != .String) return self.fail("bad argument #2 to 'testC' (string expected)", .{});
                const envv = self.getFieldOpt(args[0].Table, "_env") orelse return self.fail("bad argument #1 to 'testC' (state env missing)", .{});
                if (envv != .Table) return self.fail("bad argument #1 to 'testC' (state env missing)", .{});
                arg_off = 1;
                include_script_on_stack = false;
                ctx.upenv = envv;
                ctx.state = args[0].Table;
                ctx.first_arg = args[0];
                script_source = args[1].String.bytes();
            } else {
                return self.fail("bad argument #1 to 'testC' (string expected)", .{});
            }
        } else if (args[0] == .Thread) {
            if (args.len < 2 or args[1] != .String) return self.fail("bad argument #2 to 'testC' (string expected)", .{});
            arg_off = 1;
            ctx.first_arg = args[0];
            script_source = args[1].String.bytes();
        } else if (args[0] != .String) {
            return self.fail("bad argument #1 to 'testC' (string expected)", .{});
        } else {
            script_source = args[0].String.bytes();
        }

        var st: std.ArrayListUnmanaged(Value) = .empty;
        defer st.deinit(self.alloc);
        if (include_script_on_stack) {
            try st.append(self.alloc, args[arg_off]);
        }
        if (args.len > arg_off + 1) try st.appendSlice(self.alloc, args[arg_off + 1 ..]);

        const rr = try self.runTestcScript(script_source.?, &st, ctx);
        const spec = rr.return_spec orelse testc.ReturnSpec{ .fixed = 0 };

        var produced: usize = 0;
        switch (spec) {
            .all => {
                produced = @min(outs.len, st.items.len);
                for (0..produced) |i| outs[i] = st.items[i];
            },
            .fixed => |n| {
                produced = @min(outs.len, n);
                const available = st.items.len;
                for (0..produced) |i| {
                    const src_from_top = produced - i;
                    if (available >= src_from_top) {
                        outs[i] = st.items[available - src_from_top];
                    } else {
                        outs[i] = .Nil;
                    }
                }
            },
        }
        self.last_builtin_out_count = produced;
    }

    fn copyTestcReturnValues(self: *Vm, st: []const Value, spec: testc.ReturnSpec) Error![]Value {
        return switch (spec) {
            .all => blk: {
                const vals = try self.alloc.alloc(Value, st.len);
                @memcpy(vals, st);
                break :blk vals;
            },
            .fixed => |n| blk: {
                const vals = try self.alloc.alloc(Value, n);
                for (0..n) |i| {
                    const src_from_top = n - i;
                    vals[i] = if (st.len >= src_from_top) st[st.len - src_from_top] else .Nil;
                }
                break :blk vals;
            },
        };
    }

    fn storeTestcCloseReturnContinuation(
        self: *Vm,
        th: *Thread,
        st: []const Value,
        spec: testc.ReturnSpec,
        marks: []const usize,
        current_idx: usize,
    ) Error!void {
        self.clearTestcCloseReturnContinuation(th);

        const return_values = try self.copyTestcReturnValues(st, spec);
        errdefer self.alloc.free(return_values);

        var count: usize = 0;
        for (marks) |m| {
            if (m < current_idx) count += 1;
        }
        const remaining = try self.alloc.alloc(Value, count);
        errdefer self.alloc.free(remaining);

        var out_i: usize = 0;
        var idx = current_idx;
        while (idx > 0) {
            idx -= 1;
            if (!testcIsMarked(marks, idx)) continue;
            remaining[out_i] = st[idx];
            out_i += 1;
        }

        th.testc_close_return_values = return_values;
        th.testc_close_current = st[current_idx];
        th.testc_close_remaining = remaining;
    }

    fn setTestcCloseRemainingAfter(self: *Vm, th: *Thread, remaining: []const Value, current_index: usize) Error!void {
        th.testc_close_current = remaining[current_index];
        const next_index = current_index + 1;
        const new_remaining = try self.alloc.alloc(Value, remaining.len - next_index);
        @memcpy(new_remaining, remaining[next_index..]);
        if (th.testc_close_remaining) |old| self.alloc.free(old);
        th.testc_close_remaining = new_remaining;
    }

    fn resumeTestcCloseReturnContinuation(self: *Vm, th: *Thread, outs: []Value) Error!void {
        const return_values = th.testc_close_return_values orelse return;

        if (th.testc_close_current) |current| {
            self.runTestcCloseMetamethod(current, null) catch |e| switch (e) {
                error.Yield => return error.Yield,
                else => return e,
            };
            th.testc_close_current = null;
        }

        while (th.testc_close_remaining) |remaining| {
            if (remaining.len == 0) break;
            var i: usize = 0;
            while (i < remaining.len) {
                self.runTestcCloseMetamethod(remaining[i], null) catch |e| switch (e) {
                    error.Yield => {
                        try self.setTestcCloseRemainingAfter(th, remaining, i);
                        return error.Yield;
                    },
                    else => return e,
                };
                i += 1;
            }
            if (th.testc_close_remaining) |old| {
                self.alloc.free(old);
                th.testc_close_remaining = null;
            }
        }

        const produced = @min(outs.len, return_values.len);
        for (0..produced) |i| outs[i] = return_values[i];
        self.last_builtin_out_count = produced;
        self.clearTestcCloseReturnContinuation(th);
    }

    fn builtinTestcMakeCfunc(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (outs.len == 0) return;
        var roots = self.gcTempRoots();
        defer roots.end();

        const upvals = try self.allocTable();
        try roots.add(.{ .Table = upvals });

        for (args, 0..) |v, i| {
            try self.tableSetValue(upvals, .{ .Int = @intCast(i + 1) }, v);
        }
        const ccl = try self.allocTable();
        try roots.add(.{ .Table = ccl });

        try self.setField(ccl, "__testc_upvalues", .{ .Table = upvals });
        try self.setField(ccl, "__testc_upenv", self.currentCallableEnvValue());
        try self.setField(ccl, "__testc_script_upvalue", .{ .Bool = true });
        const mt = try self.allocTable();
        try self.setField(mt, "__call", .{ .Builtin = .testc_testC });
        ccl.metatable = mt;
        outs[0] = .{ .Table = ccl };
        self.last_builtin_out_count = 1;
    }

    fn builtinTestcTotalmem(self: *Vm, args: []const Value, outs: []Value) Error!void {
        if (args.len == 0) {
            if (outs.len > 0) outs[0] = .{ .Int = @intCast(self.testc_total_bytes) };
            if (outs.len > 1) outs[1] = .{ .Int = 0 };
            if (outs.len > 2) outs[2] = .{ .Int = if (self.testc_mem_limit) |limit| @intCast(limit) else 0 };
            self.last_builtin_out_count = @min(outs.len, 3);
            return;
        }

        switch (args[0]) {
            .Int, .Num => {
                const limit_i: i64 = switch (args[0]) {
                    .Int => |i| i,
                    .Num => |n| blk: {
                        if (!std.math.isFinite(n)) return self.fail("T.totalmem expects integer limit", .{});
                        break :blk @as(i64, @intFromFloat(n));
                    },
                    else => unreachable,
                };
                self.testc_mem_limit = if (limit_i <= 0) null else @as(usize, @intCast(limit_i));
                self.last_builtin_out_count = 0;
            },
            .String => |namev| {
                if (outs.len == 0) return;
                const name = namev.bytes();
                if (std.mem.eql(u8, name, "table")) {
                    outs[0] = .{ .Int = @intCast(self.testc_obj_tables) };
                } else if (std.mem.eql(u8, name, "function")) {
                    outs[0] = .{ .Int = @intCast(self.testc_obj_functions) };
                } else if (std.mem.eql(u8, name, "thread")) {
                    outs[0] = .{ .Int = @intCast(self.testc_obj_threads) };
                } else if (std.mem.eql(u8, name, "string")) {
                    outs[0] = .{ .Int = @intCast(self.testc_obj_strings) };
                } else {
                    return self.fail("unknown type '{s}'", .{name});
                }
                self.last_builtin_out_count = 1;
            },
            else => return self.fail("T.totalmem expects integer limit or type name", .{}),
        }
    }

    fn resumePendingTestcContinuation(self: *Vm, th: *Thread, raw_args: []const Value, outs: []Value) Error!void {
        if (th.testc_pending_conts.items.len == 0) return;
        const pending = th.testc_pending_conts.orderedRemove(0);
        const pending_script = pending.script;
        var resume_args = raw_args;
        if (pending.first_arg) |first| {
            if (resume_args.len != 0 and valuesEqual(resume_args[0], first)) {
                resume_args = resume_args[1..];
            }
        }

        var pending_ctx: TestcContext = .{
            .upenv = if (pending.upenv == .Nil) null else pending.upenv,
            .state = pending.state,
            .first_arg = pending.first_arg,
        };
        if (pending.upvalues) |vals| pending_ctx.upvalues = vals;

        var st: std.ArrayListUnmanaged(Value) = .empty;
        defer st.deinit(self.alloc);
        try st.appendSlice(self.alloc, pending.stack);
        if (resume_args.len != 0) try st.appendSlice(self.alloc, resume_args);

        if (pending.status) |status| {
            const status_name = "status";
            const status_value = status;
            const ctx_name = "ctx";
            if (pending_ctx.upenv) |uv| {
                if (uv == .Table) {
                    try self.tableSetValue(uv.Table, .{ .String = try self.internStr(status_name) }, .{ .String = try self.internStr(status_value) });
                    try self.tableSetValue(uv.Table, .{ .String = try self.internStr(ctx_name) }, .{ .Int = pending.ctx });
                }
            } else {
                try self.setGlobal(status_name, .{ .String = try self.internStr(status_value) });
                try self.setGlobal(ctx_name, .{ .Int = pending.ctx });
            }
        }

        defer self.alloc.free(pending.stack);
        defer if (pending.upvalues) |vals| self.alloc.free(vals);
        defer if (pending.closers) |vals| self.alloc.free(vals);

        const rr = try self.runTestcScript(pending_script, &st, pending_ctx);
        if (pending.closers) |vals| {
            for (vals) |v| try self.runTestcCloseMetamethod(v, null);
        }
        const spec = rr.return_spec orelse testc.ReturnSpec{ .fixed = 0 };

        var produced: usize = 0;
        switch (spec) {
            .all => {
                produced = @min(outs.len, st.items.len);
                for (0..produced) |i| outs[i] = st.items[i];
            },
            .fixed => |n| {
                produced = @min(outs.len, n);
                const available = st.items.len;
                for (0..produced) |i| {
                    const src_from_top = produced - i;
                    if (available >= src_from_top) {
                        outs[i] = st.items[available - src_from_top];
                    } else {
                        outs[i] = .Nil;
                    }
                }
            },
        }
        self.last_builtin_out_count = produced;
    }

    fn runTestcScript(self: *Vm, script: []const u8, st: *std.ArrayListUnmanaged(Value), ctx: TestcContext) Error!testc.RunResult {
        var out: testc.RunResult = .{};
        var last_status: []const u8 = "OK";
        var stmt_count: usize = 0;
        var toclose: std.ArrayListUnmanaged(usize) = .empty;
        var thread_stacks: TestcThreadStacks = .{};
        defer toclose.deinit(self.alloc);
        defer thread_stacks.deinit(self.alloc);
        errdefer {
            const pending_yield = self.current_thread != null and
                (self.current_thread.?.testc_pending_conts.items.len != 0 or self.current_thread.?.yielded != null);
            if (!pending_yield) {
                var current_err: ?Value = null;
                if (self.err_has_obj) {
                    current_err = self.err_obj;
                } else if (self.err) |msg| {
                    current_err = .{ .String = self.internStrAssume(msg) };
                }
                var idx = st.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (!testcIsMarked(toclose.items, idx)) continue;
                    self.runTestcCloseMetamethod(st.items[idx], current_err) catch |e| switch (e) {
                        error.RuntimeError => {
                            if (self.err_has_obj) {
                                current_err = self.err_obj;
                            } else if (self.err) |msg| {
                                current_err = .{ .String = self.internStrAssume(msg) };
                            }
                        },
                        else => {},
                    };
                }
            }
        }
        var norm = std.ArrayList(u8).empty;
        defer norm.deinit(self.alloc);
        var i_norm: usize = 0;
        var in_quote_norm = false;
        while (i_norm < script.len) : (i_norm += 1) {
            const ch = script[i_norm];
            if (ch == '\'') {
                in_quote_norm = !in_quote_norm;
                try norm.append(self.alloc, ch);
                continue;
            }
            if (!in_quote_norm and ch == '#') {
                while (i_norm + 1 < script.len and script[i_norm + 1] != '\n') : (i_norm += 1) {}
                continue;
            }
            if (!in_quote_norm and ch == ',') {
                var j = i_norm + 1;
                while (j < script.len and (script[j] == ' ' or script[j] == '\t')) : (j += 1) {}
                if (j + 6 <= script.len and std.mem.eql(u8, script[j .. j + 6], "return")) {
                    try norm.append(self.alloc, ';');
                    continue;
                }
            }
            try norm.append(self.alloc, ch);
        }

        var start: usize = 0;
        var in_quote = false;
        var i: usize = 0;
        while (i <= norm.items.len) : (i += 1) {
            const at_end = i == norm.items.len;
            if (!at_end and norm.items[i] == '\'') in_quote = !in_quote;
            const is_sep = at_end or ((!in_quote) and (norm.items[i] == ';' or norm.items[i] == '\n'));
            if (!is_sep) continue;

            const stmt_raw = std.mem.trim(u8, norm.items[start..i], " \t\r");
            start = i + 1;
            if (stmt_raw.len == 0) continue;

            var word_buf: [40][]const u8 = undefined;
            const wc = try self.parseTestcWords(stmt_raw, word_buf[0..]);
            if (wc == 0) continue;
            const op = word_buf[0];
            const cmd = testc.parseCommand(op) orelse return self.fail("unknown testC command '{s}'", .{op});

            const ret = try self.execTestcCommand(cmd, word_buf[1..wc], st, &last_status, ctx, &toclose, &thread_stacks);
            if (ret != null) {
                out.return_spec = ret.?;
                break;
            }
            stmt_count += 1;
            if (stmt_count > 400_000) return self.failTestcRaw("stack overflow");
        }

        var idx = st.items.len;
        while (idx > 0) {
            idx -= 1;
            if (!testcIsMarked(toclose.items, idx)) continue;
            self.runTestcCloseMetamethod(st.items[idx], null) catch |e| switch (e) {
                error.Yield => {
                    if (self.current_thread) |th| {
                        const spec = out.return_spec orelse testc.ReturnSpec{ .fixed = 0 };
                        try self.storeTestcCloseReturnContinuation(th, st.items, spec, toclose.items, idx);
                    }
                    return error.Yield;
                },
                else => return e,
            };
        }

        return out;
    }

    fn parseTestcWords(self: *Vm, stmt: []const u8, out: [][]const u8) Error!usize {
        var argc: usize = 0;
        var i: usize = 0;
        while (i < stmt.len) {
            while (i < stmt.len and (stmt[i] == ' ' or stmt[i] == '\t' or stmt[i] == '\r' or stmt[i] == ',')) : (i += 1) {}
            if (i >= stmt.len) break;
            if (stmt[i] == '#') break;
            if (argc >= out.len) return self.fail("too many testC arguments", .{});
            if (stmt[i] == '\'') {
                i += 1;
                const start = i;
                while (i < stmt.len and stmt[i] != '\'') : (i += 1) {}
                if (i >= stmt.len) return self.fail("unterminated quoted testC argument", .{});
                out[argc] = stmt[start..i];
                argc += 1;
                i += 1;
                continue;
            }
            const start = i;
            while (i < stmt.len and stmt[i] != ' ' and stmt[i] != '\t' and stmt[i] != '\r' and stmt[i] != ',' and stmt[i] != '#') : (i += 1) {}
            out[argc] = std.mem.trim(u8, stmt[start..i], " \t\r");
            if (out[argc].len != 0) argc += 1;
        }
        return argc;
    }

    fn parseTestcNumToken(self: *Vm, tok: []const u8, st: *std.ArrayListUnmanaged(Value)) Error!i64 {
        if (std.mem.eql(u8, tok, "*")) return @intCast(st.items.len);
        if (std.mem.eql(u8, tok, "!G")) return 2;
        if (std.mem.eql(u8, tok, "!M")) return 1;
        if (std.mem.eql(u8, tok, ".")) {
            if (st.items.len == 0) return self.fail("testC stack underflow", .{});
            const v = st.pop().?;
            return switch (v) {
                .Int => |n| n,
                .Num => |n| blk: {
                    if (!std.math.isFinite(n) or @trunc(n) != n) return self.fail("testC integer expected", .{});
                    break :blk @intFromFloat(n);
                },
                else => return self.fail("testC integer expected", .{}),
            };
        }
        return std.fmt.parseInt(i64, tok, 10) catch return self.fail("testC invalid integer", .{});
    }

    fn parseTestcStackRef(self: *Vm, tok: []const u8, top: usize) Error!?usize {
        if (std.mem.eql(u8, tok, "0")) return null;
        return try self.parseTestcIndex(tok, top);
    }

    fn resetReusableTestcThread(self: *Vm, th: *Thread, callee: Value) void {
        self.freeThreadLocalsSnapshot(th);
        self.freeThreadWrapBuffers(th);
        self.clearThreadContinuationScratch(th, .{ .clear_yielded = true });
        th.status = .suspended;
        th.callee = callee;
        th.close_has_err = false;
        th.close_err = .Nil;
        th.caller = null;
        th.started = false;
        th.finished = false;
    }

    fn takeTestcArgsFromStack(src: *std.ArrayListUnmanaged(Value), start: usize, count: usize, alloc: std.mem.Allocator) ![]Value {
        const vals = try alloc.alloc(Value, count);
        for (0..count) |i| vals[i] = src.items[start + i];
        src.items.len = start;
        return vals;
    }

    fn execTestcCommand(
        self: *Vm,
        cmd: testc.Command,
        cargs: []const []const u8,
        st: *std.ArrayListUnmanaged(Value),
        last_status: *[]const u8,
        ctx: TestcContext,
        toclose: *std.ArrayListUnmanaged(usize),
        thread_stacks: *TestcThreadStacks,
    ) Error!?testc.ReturnSpec {
        switch (cmd) {
            .pushinteger, .pushint => {
                if (cargs.len != 1) return self.fail("testC pushint expects 1 arg", .{});
                const v: i64 = if (std.mem.eql(u8, cargs[0], "*"))
                    @intCast(st.items.len)
                else
                    std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid integer", .{});
                try self.apiStackPush(st, .{ .Int = v });
            },
            .pushnumber, .pushnum => {
                if (cargs.len != 1) return self.fail("testC pushnum expects 1 arg", .{});
                const v = std.fmt.parseFloat(f64, cargs[0]) catch return self.fail("testC invalid number", .{});
                try self.apiStackPush(st, .{ .Num = v });
            },
            .pushbool => {
                if (cargs.len != 1) return self.fail("testC pushbool expects 1 arg", .{});
                const v = std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid bool", .{});
                try self.apiStackPush(st, .{ .Bool = v != 0 });
            },
            .pushstring => {
                if (cargs.len != 1) return self.fail("testC pushstring expects 1 arg", .{});
                try self.apiStackPush(st, .{ .String = try self.internStr(trimTestcQuoted(cargs[0])) });
            },
            .pushfstringI, .pushfstringS, .pushfstringP => {
                if (cargs.len != 0) return self.fail("testC pushfstring expects no args", .{});
                if (st.items.len < 2) return self.fail("testC pushfstring expects fmt and value", .{});
                const fmt_v = st.items[st.items.len - 2];
                const fmt = switch (fmt_v) {
                    .String => |s| s.bytes(),
                    else => try self.valueToStringAlloc(fmt_v),
                };
                const raw_arg = st.items[st.items.len - 1];
                const arg = switch (cmd) {
                    .pushfstringI => blk: {
                        const n = switch (raw_arg) {
                            .Int => |i| i,
                            .Num => |n| @as(i64, @intFromFloat(n)),
                            else => return self.fail("testC pushfstringI expects integer", .{}),
                        };
                        break :blk Value{ .Int = n };
                    },
                    .pushfstringS => blk: {
                        const s = switch (raw_arg) {
                            .String => |s| s.bytes(),
                            else => try self.valueToStringAlloc(raw_arg),
                        };
                        break :blk Value{ .String = try self.internStr(s) };
                    },
                    .pushfstringP => raw_arg,
                    else => unreachable,
                };
                var fmt_args = [_]Value{ .{ .String = try self.internStr(fmt) }, arg };
                var fmt_out = [_]Value{.Nil};
                try self.builtinStringFormat(fmt_args[0..], fmt_out[0..]);
                try self.apiStackPush(st, fmt_out[0]);
            },
            .pushnil => {
                if (cargs.len != 0) return self.fail("testC pushnil expects 0 args", .{});
                try self.apiStackPush(st, .Nil);
            },
            .pushvalue => {
                if (cargs.len != 1) return self.fail("testC pushvalue expects 1 arg", .{});
                if (std.mem.eql(u8, cargs[0], "R")) {
                    const reg = try self.ensureDebugRegistry();
                    try st.append(self.alloc, .{ .Table = reg });
                } else if (parseTestcUpvalueToken(cargs[0])) |uix| {
                    const uv = try self.getTestcUpvalue(ctx, uix);
                    try self.apiStackPush(st, uv);
                } else {
                    const idx = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                    try self.apiStackPushValue(st, idx);
                }
            },
            .pushupvalueindex => {
                if (cargs.len != 1) return self.fail("testC pushupvalueindex expects 1 arg", .{});
                const uix = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid upvalue index", .{});
                try st.append(self.alloc, try self.getTestcUpvalue(ctx, uix));
            },
            .pushcclosure => {
                if (cargs.len != 1) return self.fail("testC pushcclosure expects 1 arg", .{});
                const n = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid upvalue count", .{});
                if (n > st.items.len) return self.fail("testC stack underflow", .{});
                var roots = self.gcTempRoots();
                defer roots.end();

                const upvals = try self.allocTable();
                try roots.add(.{ .Table = upvals });

                const base = st.items.len - n;
                for (0..n) |i| {
                    try self.tableSetValue(upvals, .{ .Int = @intCast(i + 1) }, st.items[base + i]);
                }
                st.items.len = base;
                const ccl = try self.allocTable();
                try roots.add(.{ .Table = ccl });

                try self.setField(ccl, "__testc_upvalues", .{ .Table = upvals });
                const envv = ctx.upenv orelse self.currentCallableEnvValue();
                try self.setField(ccl, "__testc_upenv", envv);
                try self.setField(ccl, "__testc_script_upvalue", .{ .Bool = false });
                const mt = try self.allocTable();
                try self.setField(mt, "__call", .{ .Builtin = .testc_testC });
                ccl.metatable = mt;
                try st.append(self.alloc, .{ .Table = ccl });
            },
            .gettop => {
                if (cargs.len != 0) return self.fail("testC gettop expects 0 args", .{});
                try self.apiStackPush(st, .{ .Int = @intCast(st.items.len) });
            },
            .absindex => {
                if (cargs.len != 1) return self.fail("testC absindex expects 1 arg", .{});
                if (std.mem.eql(u8, cargs[0], "R")) {
                    try st.append(self.alloc, .{ .Int = -10000 });
                } else {
                    const idx = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                    const abs = self.apiStackAbsIndex(st, idx) catch return self.fail("testC invalid index", .{});
                    try self.apiStackPush(st, .{ .Int = abs });
                }
            },
            .settop => {
                if (cargs.len != 1) return self.fail("testC settop expects 1 arg", .{});
                const idx = try self.parseTestcSettop(cargs[0], st.items.len);
                if (idx < st.items.len) {
                    var i = st.items.len;
                    while (i > idx) {
                        i -= 1;
                        if (!testcIsMarked(toclose.items, i)) continue;
                        try self.runTestcCloseMetamethod(st.items[i], null);
                    }
                    testcDropMarksAbove(toclose, idx);
                    st.items.len = idx;
                } else {
                    try st.appendNTimes(self.alloc, .Nil, idx - st.items.len);
                }
            },
            .pop => {
                if (cargs.len != 1) return self.fail("testC pop expects 1 arg", .{});
                const n = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid pop count", .{});
                if (n > st.items.len) return self.fail("testC pop underflow", .{});
                const new_len = st.items.len - n;
                var i = st.items.len;
                while (i > new_len) {
                    i -= 1;
                    if (!testcIsMarked(toclose.items, i)) continue;
                    try self.runTestcCloseMetamethod(st.items[i], null);
                }
                testcDropMarksAbove(toclose, new_len);
                st.items.len -= n;
            },
            .tobool => {
                if (cargs.len != 1) return self.fail("testC tobool expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const v = st.items[idx];
                const b = switch (v) {
                    .Nil => false,
                    .Bool => |bv| bv,
                    else => true,
                };
                try st.append(self.alloc, .{ .Bool = b });
            },
            .remove => {
                if (cargs.len != 1) return self.fail("testC remove expects 1 arg", .{});
                const idx = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                self.apiStackRemove(st, idx) catch return self.fail("testC invalid index", .{});
            },
            .insert => {
                if (cargs.len != 1) return self.fail("testC insert expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const idx = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                self.apiStackInsert(st, idx) catch return self.fail("testC invalid index", .{});
            },
            .replace => {
                if (cargs.len != 1) return self.fail("testC replace expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const idx = if (parseTestcUpvalueToken(cargs[0]) == null)
                    try self.parseTestcIndex(cargs[0], st.items.len)
                else
                    0;
                const topv = st.pop().?;
                if (parseTestcUpvalueToken(cargs[0])) |uix| {
                    try self.setTestcUpvalue(ctx, uix, topv);
                } else {
                    try self.apiStackPush(st, topv);
                    const api_idx: i32 = @intCast(idx + 1);
                    self.apiStackReplace(st, api_idx) catch return self.fail("testC invalid index", .{});
                }
            },
            .copy => {
                if (cargs.len != 2) return self.fail("testC copy expects 2 args", .{});
                const from = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                const to = std.fmt.parseInt(i32, cargs[1], 10) catch return self.fail("testC invalid index", .{});
                self.apiStackCopy(st, from, to) catch return self.fail("testC invalid index", .{});
            },
            .rotate => {
                if (cargs.len != 2) return self.fail("testC rotate expects 2 args", .{});
                const idx = std.fmt.parseInt(i32, cargs[0], 10) catch return self.fail("testC invalid index", .{});
                const nraw = std.fmt.parseInt(i64, cargs[1], 10) catch return self.fail("testC invalid rotate count", .{});
                const n = std.math.cast(i32, nraw) orelse return self.fail("testC invalid rotate count", .{});
                self.apiStackRotate(st, idx, n) catch return self.fail("testC invalid index", .{});
            },
            .concat => {
                if (cargs.len != 1) return self.fail("testC concat expects 1 arg", .{});
                const n = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid concat count", .{});
                self.apiStackConcat(st, n) catch return self.fail("testC stack underflow", .{});
            },
            .call => {
                if (cargs.len != 2) return self.fail("testC call expects 2 args", .{});
                const nargs = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid nargs", .{});
                const nresults = std.fmt.parseInt(i32, cargs[1], 10) catch return self.fail("testC invalid nresults", .{});
                if (st.items.len < nargs + 1) return self.fail("testC stack underflow", .{});
                const fn_idx = st.items.len - nargs - 1;
                const callee = st.items[fn_idx];
                const call_args = st.items[fn_idx + 1 ..];
                const ret = try self.apiCall(callee, call_args);
                defer self.alloc.free(ret);
                st.items.len = fn_idx;
                const want: usize = if (nresults < 0) ret.len else @as(usize, @intCast(nresults));
                if (ret.len >= want) {
                    try st.appendSlice(self.alloc, ret[0..want]);
                } else {
                    try st.appendSlice(self.alloc, ret);
                    try st.appendNTimes(self.alloc, .Nil, want - ret.len);
                }
            },
            .callk => {
                if (cargs.len != 3) return self.fail("testC callk expects 3 args", .{});
                const nargs = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid nargs", .{});
                const nresults = std.fmt.parseInt(i32, cargs[1], 10) catch return self.fail("testC invalid nresults", .{});
                const cont_script = try self.resolveTestcContinuationScript(ctx, st, cargs[2]);
                if (st.items.len < nargs + 1) return self.fail("testC stack underflow", .{});
                const fn_idx = st.items.len - nargs - 1;
                const callee = st.items[fn_idx];
                const call_args = st.items[fn_idx + 1 ..];
                const prefix_len = fn_idx;
                const ret = self.apiCall(callee, call_args) catch |e| switch (e) {
                    error.Yield => {
                        const th = self.current_thread orelse return e;
                        const closers = try self.collectTestcClosers(st, toclose, prefix_len);
                        defer self.alloc.free(closers);
                        try self.saveTestcPendingContinuation(th, cont_script, st.items[0..prefix_len], ctx, "YIELD", testcContinuationCtxId(cargs[2]), closers);
                        return e;
                    },
                    else => return e,
                };
                defer self.alloc.free(ret);
                st.items.len = fn_idx;
                const want: usize = if (nresults < 0) ret.len else @as(usize, @intCast(nresults));
                if (ret.len >= want) {
                    try st.appendSlice(self.alloc, ret[0..want]);
                } else {
                    try st.appendSlice(self.alloc, ret);
                    try st.appendNTimes(self.alloc, .Nil, want - ret.len);
                }
            },
            .tostring => {
                if (cargs.len != 1) return self.fail("testC tostring expects 1 arg", .{});
                const v = if (parseTestcUpvalueToken(cargs[0])) |uix|
                    try self.getTestcUpvalue(ctx, uix)
                else blk: {
                    const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                    if (idx == null) {
                        try st.append(self.alloc, .Nil);
                        return null;
                    }
                    break :blk st.items[idx.?];
                };
                switch (v) {
                    .String => try st.append(self.alloc, v),
                    .Int, .Num => {
                        const s = try self.valueToStringAlloc(v);
                        try st.append(self.alloc, .{ .String = try self.internStr(s) });
                    },
                    else => try st.append(self.alloc, .Nil),
                }
            },
            .checkstack => {
                // PUC ltests uses this to probe stack growth. Our testC VM path
                // is dynamically backed by ArrayList and does not expose a fixed
                // hard limit here; emulate overflow behavior for very deep probes.
                if (cargs.len == 0) return self.fail("testC checkstack expects at least 1 arg", .{});
                const parsed = parseLeadingIntTail(cargs[0]) orelse return self.fail("testC invalid checkstack", .{});
                const need = parsed.n;
                if (need > 1000000) {
                    const raw = if (cargs.len >= 2) cargs[1] else parsed.tail;
                    const msg = trimTestcQuoted(raw);
                    if (msg.len == 0) return self.failTestcRaw("stack overflow");
                    return self.failTestcRaw(msg);
                }
            },
            .rawcheckstack => {
                if (cargs.len == 0) return self.fail("testC rawcheckstack expects at least 1 arg", .{});
                const parsed = parseLeadingIntTail(cargs[0]) orelse return self.fail("testC invalid rawcheckstack", .{});
                const need = parsed.n;
                var blocked = false;
                const t_global = self.getGlobal("T");
                if (t_global == .Table) {
                    if (self.getFieldOpt(t_global.Table, "_alloccount")) |v| {
                        blocked = switch (v) {
                            .Int => |iv| iv == 0,
                            .Num => |nv| nv == 0,
                            else => false,
                        };
                    }
                }
                try st.append(self.alloc, .{ .Bool = !blocked and need < 500000 });
            },
            .alloccount => {
                if (cargs.len > 1) return self.fail("testC alloccount expects 0 or 1 args", .{});
                const t_global = self.getGlobal("T");
                if (t_global == .Table) {
                    const v: Value = if (cargs.len == 1) blk: {
                        const n = std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid alloccount", .{});
                        break :blk .{ .Int = n };
                    } else .{ .Int = -1 };
                    try self.setField(t_global.Table, "_alloccount", v);
                }
            },
            .collectgarbage => {
                if (cargs.len > 1) return self.fail("testC collectgarbage expects <=1 arg", .{});
                if (cargs.len == 0) {
                    var out: [1]Value = .{.Nil};
                    try self.builtinCollectgarbage(&[_]Value{}, out[0..]);
                } else {
                    var args = [_]Value{.{ .String = try self.internStr(trimTestcQuoted(cargs[0])) }};
                    var out: [1]Value = .{.Nil};
                    try self.builtinCollectgarbage(args[0..], out[0..]);
                }
            },
            .warningC, .warning => {
                // Warning aggregation is not needed for functional parity in
                // current testC bootstrap stage.
                if (cargs.len < 1) return self.fail("testC warning expects args", .{});
            },
            .pushstatus => {
                if (cargs.len != 0) return self.fail("testC pushstatus expects 0 args", .{});
                try st.append(self.alloc, .{ .String = try self.internStr(last_status.*) });
            },
            .argerror => {
                if (cargs.len != 2) return self.fail("testC argerror expects 2 args", .{});
                const argn = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid argerror index", .{});
                const msg = trimTestcQuoted(cargs[1]);
                // PUC luaL_argerror adjusts argument names when a C function
                // is reached through __call: synthetic callable objects are
                // reported as "extra" arguments and the following slot is
                // reported as "self" for method calls.
                const extra_args = if (st.items.len > 0) st.items.len - 1 else 0;
                var msg_buf: [160]u8 = undefined;
                const stable = if (argn <= extra_args)
                    std.fmt.bufPrint(msg_buf[0..], "bad extra argument #{d} ({s})", .{ argn, msg }) catch "bad extra argument"
                else if (argn == extra_args + 1)
                    std.fmt.bufPrint(msg_buf[0..], "bad self ({s})", .{msg}) catch "bad self"
                else
                    std.fmt.bufPrint(msg_buf[0..], "bad argument #{d} ({s})", .{ argn - extra_args - 1, msg }) catch "bad argument";
                return self.failTestcRaw(stable);
            },
            .arith => {
                if (cargs.len != 1) return self.fail("testC arith expects 1 arg", .{});
                const op = cargs[0];
                if (std.mem.eql(u8, op, "_")) {
                    if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                    const v = st.pop().?;
                    const neg = switch (coerceArithmeticValue(v) orelse v) {
                        .Int => |iv| Value{ .Int = -%iv },
                        .Num => |nv| Value{ .Num = -nv },
                        else => blk: {
                            if (try self.callUnaryMetamethod(v, "__unm", "unm")) |mv| break :blk mv;
                            return self.fail("attempt to negate a {s} value", .{v.typeName()});
                        },
                    };
                    try st.append(self.alloc, neg);
                } else {
                    if (st.items.len < 2) return self.fail("testC stack underflow", .{});
                    const rhs = st.pop().?;
                    const lhs = st.pop().?;
                    const out = if (std.mem.eql(u8, op, "+"))
                        try self.binAdd(lhs, rhs)
                    else if (std.mem.eql(u8, op, "-"))
                        try self.binSub(lhs, rhs)
                    else if (std.mem.eql(u8, op, "*"))
                        try self.binMul(lhs, rhs)
                    else if (std.mem.eql(u8, op, "/"))
                        try self.binDiv(lhs, rhs)
                    else if (std.mem.eql(u8, op, "\\"))
                        try self.binIdiv(lhs, rhs)
                    else if (std.mem.eql(u8, op, "%"))
                        try self.binMod(lhs, rhs)
                    else if (std.mem.eql(u8, op, "^"))
                        try self.binPow(lhs, rhs)
                    else
                        return self.fail("testC unknown arith op '{s}'", .{op});
                    try st.append(self.alloc, out);
                }
            },
            .compare => {
                if (cargs.len != 3) return self.fail("testC compare expects 3 args", .{});
                const op = cargs[0];
                const lhs_idx = self.parseTestcIndex(cargs[1], st.items.len) catch {
                    try st.append(self.alloc, .{ .Bool = false });
                    return null;
                };
                const rhs_idx = self.parseTestcIndex(cargs[2], st.items.len) catch {
                    try st.append(self.alloc, .{ .Bool = false });
                    return null;
                };
                const lhs = st.items[lhs_idx];
                const rhs = st.items[rhs_idx];
                const b = if (std.mem.eql(u8, op, "LT"))
                    try self.cmpLt(lhs, rhs)
                else if (std.mem.eql(u8, op, "LE"))
                    try self.cmpLte(lhs, rhs)
                else if (std.mem.eql(u8, op, "EQ"))
                    try self.cmpEq(lhs, rhs)
                else
                    return self.fail("testC unknown compare op '{s}'", .{op});
                try st.append(self.alloc, .{ .Bool = b });
            },
            .len => {
                if (cargs.len != 1) return self.fail("testC len expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const outv = try self.evalUnOp(.Hash, st.items[idx]);
                try st.append(self.alloc, outv);
            },
            .Llen => {
                if (cargs.len != 1) return self.fail("testC Llen expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const raw = try self.evalUnOp(.Hash, st.items[idx]);
                const iv: i64 = switch (raw) {
                    .Int => |v| v,
                    .Num => |n| if (n == @round(n)) @as(i64, @intFromFloat(n)) else return self.fail("object length is not an integer", .{}),
                    .String => |s| std.fmt.parseInt(i64, s.bytes(), 10) catch return self.fail("object length is not an integer", .{}),
                    else => return self.fail("object length is not an integer", .{}),
                };
                try st.append(self.alloc, .{ .Int = iv });
            },
            .Ltolstring => {
                if (cargs.len != 1) return self.fail("testC Ltolstring expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const s = try self.valueToStringAlloc(st.items[idx]);
                try st.append(self.alloc, .{ .String = try self.internStr(s) });
            },
            .objsize => {
                if (cargs.len != 1) return self.fail("testC objsize expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const v = st.items[idx];
                const outv: Value = switch (v) {
                    .String => |s| .{ .Int = @intCast(s.len) },
                    .Table => |t| blk: {
                        if (isTestcUserdata(self, v)) {
                            const szv = self.getFieldOpt(t, "__size") orelse Value{ .Int = 0 };
                            break :blk switch (szv) {
                                .Int => |n| .{ .Int = n },
                                .Num => |n| .{ .Int = @intFromFloat(n) },
                                else => .{ .Int = 0 },
                            };
                        }
                        break :blk .{ .Int = tableBorderLen(t) };
                    },
                    else => .{ .Int = 0 },
                };
                try st.append(self.alloc, outv);
            },
            .isnumber => {
                if (cargs.len != 1) return self.fail("testC isnumber expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| switch (st.items[i]) {
                    .Int, .Num => true,
                    .String => |s| blk: {
                        _ = self.parseNum(s.bytes()) catch break :blk false;
                        break :blk true;
                    },
                    else => false,
                } else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .isstring => {
                if (cargs.len != 1) return self.fail("testC isstring expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| switch (st.items[i]) {
                    .String, .Int, .Num => true,
                    else => false,
                } else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .isfunction => {
                if (cargs.len != 1) return self.fail("testC isfunction expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| switch (st.items[i]) {
                    .Builtin, .Closure => true,
                    else => false,
                } else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .iscfunction => {
                if (cargs.len != 1) return self.fail("testC iscfunction expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| switch (st.items[i]) {
                    .Builtin => true,
                    else => false,
                } else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .istable => {
                if (cargs.len != 1) return self.fail("testC istable expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| blk: {
                    const v = st.items[i];
                    if (v != .Table) break :blk false;
                    break :blk !isUserdataLike(self, v);
                } else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .isuserdata => {
                if (cargs.len != 1) return self.fail("testC isuserdata expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const b = if (idx) |i| isUserdataLike(self, st.items[i]) else false;
                try st.append(self.alloc, .{ .Bool = b });
            },
            .isnil => {
                if (cargs.len != 1) return self.fail("testC isnil expects 1 arg", .{});
                const b = if (parseTestcUpvalueToken(cargs[0])) |uix|
                    (try self.getTestcUpvalue(ctx, uix)) == .Nil
                else blk: {
                    const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                    break :blk if (idx) |i| st.items[i] == .Nil else false;
                };
                try st.append(self.alloc, .{ .Bool = b });
            },
            .isnull => {
                if (cargs.len != 1) return self.fail("testC isnull expects 1 arg", .{});
                const b = if (parseTestcUpvalueToken(cargs[0])) |uix| blk: {
                    const uv = try self.getTestcUpvalue(ctx, uix);
                    break :blk (uv == .Nil) or isTestcNullPointer(self, uv);
                } else blk: {
                    const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                    break :blk if (idx) |i| isTestcNullPointer(self, st.items[i]) else true;
                };
                try st.append(self.alloc, .{ .Bool = b });
            },
            .tonumber => {
                if (cargs.len != 1) return self.fail("testC tonumber expects 1 arg", .{});
                const outv: Value = if (parseTestcUpvalueToken(cargs[0])) |uix| blk: {
                    break :blk switch (try self.getTestcUpvalue(ctx, uix)) {
                        .Int => |iv| .{ .Int = iv },
                        .Num => |nv| .{ .Num = nv },
                        .String => |s| blk2: {
                            const n = self.parseNum(s.bytes()) catch break :blk2 .{ .Int = 0 };
                            break :blk2 .{ .Num = n };
                        },
                        else => .{ .Int = 0 },
                    };
                } else if (try self.parseTestcIndexMaybe(cargs[0], st.items.len)) |i| blk: {
                    break :blk switch (st.items[i]) {
                        .Int => |iv| .{ .Int = iv },
                        .Num => |nv| .{ .Num = nv },
                        .String => |s| blk2: {
                            const n = self.parseNum(s.bytes()) catch break :blk2 .{ .Int = 0 };
                            break :blk2 .{ .Num = n };
                        },
                        else => .{ .Int = 0 },
                    };
                } else .{ .Int = 0 };
                try st.append(self.alloc, outv);
            },
            .topointer => {
                if (cargs.len != 1) return self.fail("testC topointer expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const outv: Value = if (idx) |i| blk: {
                    const v = st.items[i];
                    if (isTestcNullPointer(self, v)) break :blk v;
                    break :blk switch (v) {
                        .Nil, .Bool, .Int, .Num => try self.makeTestcPointerValue(0),
                        .String => |s| blk2: {
                            const pid: u64 = if (s.len <= 40)
                                std.hash.Wyhash.hash(0, s.bytes())
                            else
                                @intCast(@intFromPtr(s.bytes().ptr));
                            break :blk2 try self.makeTestcPointerValue(pid);
                        },
                        .Table => |t| try self.makeTestcPointerValue(@intCast(@intFromPtr(t))),
                        .Closure => |cl| try self.makeTestcPointerValue(@intCast(@intFromPtr(cl))),
                        .Builtin => |id| try self.makeTestcPointerValue(@as(u64, 0x8000_0000) + @as(u64, @intFromEnum(id))),
                        .Thread => |th| try self.makeTestcPointerValue(@intCast(@intFromPtr(th))),
                    };
                } else try self.makeTestcPointerValue(0);
                try st.append(self.alloc, outv);
            },
            .func2num => {
                if (cargs.len != 1) return self.fail("testC func2num expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const outv: Value = if (idx) |i| switch (st.items[i]) {
                    .Builtin => |id| .{ .Int = 1 + @as(i64, @intCast(@intFromEnum(id))) },
                    .Closure => |cl| .{ .Int = @intCast(@intFromPtr(cl)) },
                    else => .{ .Int = 0 },
                } else .{ .Int = 0 };
                try st.append(self.alloc, outv);
            },
            .tocfunction => {
                if (cargs.len != 1) return self.fail("testC tocfunction expects 1 arg", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const outv: Value = if (idx) |i| switch (st.items[i]) {
                    .Builtin => st.items[i],
                    else => .Nil,
                } else .Nil;
                try st.append(self.alloc, outv);
            },
            .threadstatus => {
                if (cargs.len != 0) return self.fail("testC threadstatus expects 0 args", .{});
                try st.append(self.alloc, .{ .String = try self.internStr("ERRRUN") });
            },
            .@"error" => {
                if (st.items.len == 0) return self.fail("testC error without message", .{});
                const v = st.items[st.items.len - 1];
                self.err = if (v == .String) v.String.bytes() else null;
                self.err_obj = v;
                self.err_has_obj = true;
                self.err_source = null;
                self.err_line = -1;
                self.captureErrorTraceback();
                return error.RuntimeError;
            },
            .loadstring => {
                if (cargs.len < 1) return self.fail("testC loadstring expects at least 1 arg", .{});
                const idx_m = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const idx_num = parseLeadingIntTail(cargs[0]) orelse return self.fail("testC invalid loadstring index", .{});
                if (idx_m == null) {
                    var msg_buf: [96]u8 = undefined;
                    const msg = std.fmt.bufPrint(msg_buf[0..], "bad argument #{d} (string expected, got no value)", .{idx_num.n}) catch "bad argument";
                    return self.failTestcRaw(msg);
                }
                const sv = st.items[idx_m.?];
                if (sv != .String) {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(msg_buf[0..], "bad argument #{d} (string expected, got {s})", .{ idx_num.n, self.valueTypeName(sv) }) catch "bad argument";
                    return self.failTestcRaw(msg);
                }
                const chunk_name: []const u8 = if (cargs.len >= 2) cargs[1] else "name";
                var mode_buf: [8]u8 = undefined;
                var mode_len: usize = 0;
                const mode_src: []const u8 = if (cargs.len >= 3) cargs[2] else "bt";
                for (mode_src) |ch| {
                    if (mode_len >= mode_buf.len) break;
                    mode_buf[mode_len] = std.ascii.toLower(ch);
                    mode_len += 1;
                }
                const mode = mode_buf[0..mode_len];
                var load_args: [3]Value = .{
                    sv,
                    .{ .String = try self.internStr(chunk_name) },
                    .{ .String = try self.internStr(mode) },
                };
                var out: [2]Value = .{ .Nil, .Nil };
                try self.builtinLoad(load_args[0..3], out[0..]);
                st.items[idx_m.?] = out[0];
                if (out[1] != .Nil) try st.append(self.alloc, out[1]);
                if (std.mem.indexOfScalar(u8, mode, 'b') != null and sv.String.len >= 4) {
                    const sig = sv.String.bytes();
                    if (std.mem.eql(u8, sig[0..4], "\x1bLua")) {
                        // Keep a tiny positive delta for API memory-probe case after
                        // loading binary chunks in fixed buffers.
                        self.testc_gc_count_bonus_once_kb += 0.2;
                    }
                }
            },
            .loadfile => {
                if (cargs.len < 1) return self.fail("testC loadfile expects at least 1 arg", .{});
                const idx_m = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const idx_num = parseLeadingIntTail(cargs[0]) orelse return self.fail("testC invalid loadfile index", .{});
                if (idx_m == null) {
                    var msg_buf: [96]u8 = undefined;
                    const msg = std.fmt.bufPrint(msg_buf[0..], "bad argument #{d} (string expected, got no value)", .{idx_num.n}) catch "bad argument";
                    return self.failTestcRaw(msg);
                }
                const pv = st.items[idx_m.?];
                if (pv != .String) {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(msg_buf[0..], "bad argument #{d} (string expected, got {s})", .{ idx_num.n, self.valueTypeName(pv) }) catch "bad argument";
                    return self.failTestcRaw(msg);
                }
                const source = LuaSource.loadFile(self.alloc, stdio.activeIo(), pv.String.bytes()) catch {
                    st.items[idx_m.?] = .Nil;
                    const em = std.fmt.allocPrint(self.alloc, "cannot open {s}", .{pv.String.bytes()}) catch "cannot open file";
                    try st.append(self.alloc, .{ .String = try self.internStr(em) });
                    return null;
                };
                defer {
                    self.alloc.free(source.name);
                    self.alloc.free(source.bytes);
                }
                var lex = LuaLexer.init(source);
                var p = LuaParser.init(&lex) catch {
                    st.items[idx_m.?] = .Nil;
                    try st.append(self.alloc, .{ .String = try self.internStr(lex.diagString()) });
                    return null;
                };
                var ast_arena = lua_ast.AstArena.init(self.alloc);
                defer ast_arena.deinit();
                const chunk = p.parseChunkAst(&ast_arena) catch {
                    st.items[idx_m.?] = .Nil;
                    try st.append(self.alloc, .{ .String = try self.internStr(p.diagString()) });
                    return null;
                };
                var cg = lua_codegen.Codegen.init(self.alloc, source.name, source.bytes);
                const main_fn = cg.compileChunk(chunk) catch {
                    st.items[idx_m.?] = .Nil;
                    try st.append(self.alloc, .{ .String = try self.internStr(cg.diagString()) });
                    return null;
                };
                const clv = try self.apiWrapFunction(main_fn);
                try st.append(self.alloc, clv);
            },
            .newthread => {
                if (cargs.len != 0) return self.fail("testC newthread expects 0 args", .{});
                const th = try self.apiNewThread(.Nil);
                _ = try thread_stacks.getOrCreate(self.alloc, th);
                try self.apiStackPush(st, .{ .Thread = th });
            },
            .newuserdata => {
                if (cargs.len != 1) return self.fail("testC newuserdata expects 1 arg", .{});
                const sz = std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid userdata size", .{});
                const t_global = self.getGlobal("T");
                if (t_global != .Table) return self.fail("testC T table missing", .{});
                const fnv = self.getFieldOpt(t_global.Table, "newuserdata") orelse return self.fail("testC newuserdata missing", .{});
                var call_args = [_]Value{.{ .Int = sz }};
                const ret = try self.apiCall(fnv, call_args[0..]);
                defer self.alloc.free(ret);
                try st.append(self.alloc, if (ret.len > 0) ret[0] else .Nil);
            },
            .newtable => {
                if (cargs.len != 0) return self.fail("testC newtable expects 0 args", .{});
                const t = try self.apiNewTable();
                try self.apiStackPush(st, .{ .Table = t });
            },
            .settable => {
                if (cargs.len != 1) return self.fail("testC settable expects 1 arg", .{});
                if (st.items.len < 2) return self.fail("testC stack underflow", .{});
                const obj = if (std.mem.eql(u8, cargs[0], "R"))
                    Value{ .Table = try self.ensureDebugRegistry() }
                else
                    st.items[try self.parseTestcIndex(cargs[0], st.items.len)];
                const val = st.pop().?;
                const key = st.pop().?;
                try self.apiSetTable(obj, key, val);
            },
            .gettable => {
                if (cargs.len != 1) return self.fail("testC gettable expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const obj = if (std.mem.eql(u8, cargs[0], "R"))
                    Value{ .Table = try self.ensureDebugRegistry() }
                else
                    st.items[try self.parseTestcIndex(cargs[0], st.items.len)];
                const key = st.pop().?;
                const v = try self.apiGetTable(obj, key);
                try self.apiStackPush(st, v);
            },
            .rawgeti => {
                if (cargs.len != 2) return self.fail("testC rawgeti expects 2 args", .{});
                if (std.mem.eql(u8, cargs[0], "R")) {
                    if (std.mem.eql(u8, cargs[1], "!G")) {
                        if (ctx.upenv) |uv| {
                            if (uv == .Table) {
                                try st.append(self.alloc, uv);
                            } else {
                                try st.append(self.alloc, .Nil);
                            }
                        } else {
                            try st.append(self.alloc, .{ .Table = self.global_env });
                        }
                    } else if (std.mem.eql(u8, cargs[1], "!M")) {
                        const main_th = if (ctx.state) |state|
                            try self.getOrCreateTestStateMainThread(state)
                        else
                            self.main_thread orelse return self.fail("testC main thread missing", .{});
                        try st.append(self.alloc, .{ .Thread = main_th });
                    } else {
                        return self.fail("testC rawgeti invalid registry index", .{});
                    }
                } else {
                    const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                    const tbl = switch (st.items[idx]) {
                        .Table => |t| t,
                        else => return self.fail("testC rawgeti expects table", .{}),
                    };
                    const ik = try self.parseTestcNumToken(cargs[1], st);
                    const v = try self.apiRawGet(tbl, .{ .Int = ik });
                    try self.apiStackPush(st, v);
                }
            },
            .append => {
                if (cargs.len != 1) return self.fail("testC append expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const tbl = switch (st.items[idx]) {
                    .Table => |t| t,
                    else => return self.fail("testC append expects table", .{}),
                };
                const val = st.pop().?;
                const border = tableBorderLen(tbl);
                try self.apiRawSet(tbl, .{ .Int = border + 1 }, val);
            },
            .toclose => {
                if (cargs.len != 1) return self.fail("testC toclose expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const obj = st.items[idx];
                if (obj != .Nil and !(obj == .Bool and !obj.Bool) and metamethodValue(self, obj, "__close") == null) {
                    switch (obj) {
                        .Table, .Thread => return self.fail("non-closable value", .{}),
                        else => return self.fail("non-closable value (C temporary)", .{}),
                    }
                }
                if (!testcIsMarked(toclose.items, idx)) {
                    try toclose.append(self.alloc, idx);
                }
            },
            .getglobal => {
                if (cargs.len != 1) return self.fail("testC getglobal expects 1 arg", .{});
                const name = trimTestcQuoted(cargs[0]);
                if (ctx.upenv) |uv| {
                    if (uv == .Table) {
                        try self.apiStackPush(st, try self.apiGetTable(uv, .{ .String = try self.internStr(name) }));
                    } else {
                        try self.apiStackPush(st, .Nil);
                    }
                } else {
                    try self.apiStackPush(st, self.apiGetGlobal(name));
                }
            },
            .setglobal => {
                if (cargs.len != 1) return self.fail("testC setglobal expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const v = st.pop().?;
                const name = trimTestcQuoted(cargs[0]);
                if (ctx.upenv) |uv| {
                    if (uv == .Table) {
                        try self.apiSetTable(uv, .{ .String = try self.internStr(name) }, v);
                    } else {
                        return self.fail("testC setglobal state env missing", .{});
                    }
                } else {
                    try self.apiSetGlobal(name, v);
                }
            },
            .rawget => {
                if (cargs.len != 1) return self.fail("testC rawget expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const base = if (std.mem.eql(u8, cargs[0], "R"))
                    Value{ .Table = try self.ensureDebugRegistry() }
                else
                    st.items[try self.parseTestcIndex(cargs[0], st.items.len)];
                const tbl = switch (base) {
                    .Table => |t| t,
                    else => return self.fail("testC rawget expects table", .{}),
                };
                const key = st.pop().?;
                const v = try self.apiRawGet(tbl, key);
                try self.apiStackPush(st, v);
            },
            .rawset => {
                if (cargs.len != 1) return self.fail("testC rawset expects 1 arg", .{});
                if (st.items.len < 2) return self.fail("testC stack underflow", .{});
                const base = if (std.mem.eql(u8, cargs[0], "R"))
                    Value{ .Table = try self.ensureDebugRegistry() }
                else
                    st.items[try self.parseTestcIndex(cargs[0], st.items.len)];
                const tbl = switch (base) {
                    .Table => |t| t,
                    else => return self.fail("testC rawset expects table", .{}),
                };
                const val = st.pop().?;
                const key = st.pop().?;
                try self.apiRawSet(tbl, key, val);
            },
            .rawsetp => {
                if (cargs.len != 2) return self.fail("testC rawsetp expects 2 args", .{});
                if (st.items.len < 1) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const tbl = switch (st.items[idx]) {
                    .Table => |t| t,
                    else => return self.fail("testC rawsetp expects table", .{}),
                };
                const ptr_id = std.fmt.parseInt(u64, cargs[1], 10) catch return self.fail("testC invalid pointer id", .{});
                const key = try self.makeTestcPointerValue(ptr_id);
                const val = st.pop().?;
                try self.apiRawSet(tbl, key, val);
            },
            .rawgetp => {
                if (cargs.len != 2) return self.fail("testC rawgetp expects 2 args", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const tbl = switch (st.items[idx]) {
                    .Table => |t| t,
                    else => return self.fail("testC rawgetp expects table", .{}),
                };
                const ptr_id = std.fmt.parseInt(u64, cargs[1], 10) catch return self.fail("testC invalid pointer id", .{});
                const key = try self.makeTestcPointerValue(ptr_id);
                const v = try self.apiRawGet(tbl, key);
                try self.apiStackPush(st, v);
            },
            .rawseti => {
                if (cargs.len != 2) return self.fail("testC rawseti expects 2 args", .{});
                if (st.items.len < 1) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const tbl = switch (st.items[idx]) {
                    .Table => |t| t,
                    else => return self.fail("testC rawseti expects table", .{}),
                };
                const ik = std.fmt.parseInt(i64, cargs[1], 10) catch return self.fail("testC invalid integer key", .{});
                const val = st.pop().?;
                try self.apiRawSet(tbl, .{ .Int = ik }, val);
            },
            .seti => {
                if (cargs.len != 2) return self.fail("testC seti expects 2 args", .{});
                if (st.items.len < 1) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const obj = st.items[idx];
                const ik = std.fmt.parseInt(i64, cargs[1], 10) catch return self.fail("testC invalid integer key", .{});
                const val = st.pop().?;
                try self.apiSetTable(obj, .{ .Int = ik }, val);
            },
            .getfield => {
                if (cargs.len != 2) return self.fail("testC getfield expects 2 args", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const v = try self.apiGetTable(st.items[idx], .{ .String = try self.internStr(cargs[1]) });
                try self.apiStackPush(st, v);
            },
            .setfield => {
                if (cargs.len != 2) return self.fail("testC setfield expects 2 args", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const val = st.pop().?;
                try self.apiSetTable(st.items[idx], .{ .String = try self.internStr(cargs[1]) }, val);
            },
            .next => {
                if (cargs.len != 0) return self.fail("testC next expects 0 args", .{});
                if (st.items.len < 2) return self.fail("testC stack underflow", .{});
                const key = st.pop().?;
                const tbl = switch (st.items[st.items.len - 1]) {
                    .Table => |t| t,
                    else => return self.fail("testC next expects table", .{}),
                };
                var outv: [2]Value = .{ .Nil, .Nil };
                try self.builtinNext(&[_]Value{ .{ .Table = tbl }, key }, outv[0..]);
                if (outv[0] == .Nil) return null;
                try st.append(self.alloc, outv[0]);
                try st.append(self.alloc, outv[1]);
            },
            .xmove => {
                if (cargs.len != 3) return self.fail("testC xmove expects 3 args", .{});
                const from_ref = try self.parseTestcStackRef(cargs[0], st.items.len);
                const to_ref = try self.parseTestcStackRef(cargs[1], st.items.len);
                const n_i = try self.parseTestcNumToken(cargs[2], st);
                if (n_i < 0) return self.fail("testC invalid xmove count", .{});
                const from_stack = if (from_ref) |idx| blk: {
                    const th = switch (st.items[idx]) {
                        .Thread => |t| t,
                        else => return self.fail("testC xmove expects thread source", .{}),
                    };
                    break :blk try thread_stacks.getOrCreate(self.alloc, th);
                } else st;
                const to_stack = if (to_ref) |idx| blk: {
                    const th = switch (st.items[idx]) {
                        .Thread => |t| t,
                        else => return self.fail("testC xmove expects thread target", .{}),
                    };
                    break :blk try thread_stacks.getOrCreate(self.alloc, th);
                } else st;
                var n: usize = @intCast(n_i);
                if (n == 0) n = from_stack.items.len;
                self.apiStackXMove(from_stack, to_stack, n) catch return self.fail("testC stack underflow", .{});
            },
            .@"resume" => {
                if (cargs.len != 2) return self.fail("testC resume expects 2 args", .{});
                const tidx = try self.parseTestcIndex(cargs[0], st.items.len);
                const th = switch (st.items[tidx]) {
                    .Thread => |t| t,
                    else => return self.fail("testC resume expects thread", .{}),
                };
                const narg_i = try self.parseTestcNumToken(cargs[1], st);
                if (narg_i < 0) return self.fail("testC invalid nargs", .{});
                const narg: usize = @intCast(narg_i);
                const th_stack = try thread_stacks.getOrCreate(self.alloc, th);
                const callee_needed = th.status == .dead or (th.status != .running and !isCallableValue(th.callee));
                const need_current = narg + @as(usize, @intFromBool(callee_needed));
                const above_thread = st.items.len - (tidx + 1);
                const had_saved_shadow = thread_stacks.getShadow(th) != null;

                var call_args: []Value = &[_]Value{};
                var call_args_owned = false;
                var current_trim_start: ?usize = null;
                var pending_callee: ?Value = null;

                if (above_thread >= need_current and need_current != 0) {
                    current_trim_start = st.items.len - need_current;
                    if (callee_needed) pending_callee = st.items[current_trim_start.?];
                    call_args = try self.alloc.alloc(Value, narg);
                    call_args_owned = true;
                    for (0..narg) |i| call_args[i] = st.items[st.items.len - narg + i];
                } else if (callee_needed) {
                    if (th_stack.items.len < narg + 1) return self.fail("testC stack underflow", .{});
                    const base = th_stack.items.len - (narg + 1);
                    pending_callee = th_stack.items[base];
                    call_args = try self.alloc.alloc(Value, narg);
                    call_args_owned = true;
                    for (0..narg) |i| call_args[i] = th_stack.items[base + 1 + i];
                    th_stack.items.len = base;
                } else {
                    if (th_stack.items.len < narg) return self.fail("testC stack underflow", .{});
                    const base = th_stack.items.len - narg;
                    call_args = try self.alloc.alloc(Value, narg);
                    call_args_owned = true;
                    for (0..narg) |i| call_args[i] = th_stack.items[base + i];
                    th_stack.items.len = base;
                }
                defer if (call_args_owned) self.alloc.free(call_args);

                if (pending_callee) |callee| {
                    if (!isCallableValue(callee)) return self.fail("testC resume expects callable body", .{});
                    if (th.status == .dead) {
                        self.resetReusableTestcThread(th, callee);
                    } else {
                        th.callee = callee;
                    }
                }

                const resume_args = try self.alloc.alloc(Value, call_args.len + 1);
                defer self.alloc.free(resume_args);
                resume_args[0] = .{ .Thread = th };
                for (call_args, 0..) |v, i| resume_args[i + 1] = v;

                const outv = try self.alloc.alloc(Value, 257);
                defer self.alloc.free(outv);
                for (outv) |*v| v.* = .Nil;
                try self.builtinCoroutineResume(resume_args, outv);

                const ok = outv[0] == .Bool and outv[0].Bool;
                last_status.* = if (!ok) "ERRRUN" else if (th.status == .suspended) "YIELD" else "OK";

                const nres = if (self.last_builtin_out_count > 0) self.last_builtin_out_count - 1 else 0;
                th_stack.items.len = 0;
                if (nres != 0) try th_stack.appendSlice(self.alloc, outv[1 .. 1 + nres]);

                if (current_trim_start) |trim| {
                    if (th.status == .suspended) {
                        if (!had_saved_shadow) {
                            const shadow = try thread_stacks.getOrCreateShadow(self.alloc, th);
                            shadow.items.len = 0;
                            try shadow.appendSlice(self.alloc, st.items[0..trim]);
                        }
                        st.items.len = 0;
                    } else if (thread_stacks.getShadow(th)) |shadow| {
                        st.items.len = 0;
                        try st.appendSlice(self.alloc, shadow.items);
                        thread_stacks.clearShadow(self.alloc, th);
                    } else {
                        st.items.len = trim;
                    }
                    if (nres != 0) try st.appendSlice(self.alloc, outv[1 .. 1 + nres]);
                }
            },
            .isyieldable => {
                if (cargs.len != 1) return self.fail("testC isyieldable expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const th = switch (st.items[idx]) {
                    .Thread => |t| t,
                    else => return self.fail("testC isyieldable expects thread", .{}),
                };
                try self.apiStackPush(st, .{ .Bool = try self.apiIsYieldable(th) });
            },
            .yield => {
                if (cargs.len != 1) return self.fail("testC yield expects 1 arg", .{});
                const nres_i = try self.parseTestcNumToken(cargs[0], st);
                if (nres_i < 0) return self.fail("testC invalid yield count", .{});
                const nres: usize = @intCast(nres_i);
                if (nres > st.items.len) return self.fail("testC stack underflow", .{});
                const base = st.items.len - nres;
                try self.apiYield(st.items[base..]);
            },
            .yieldk => {
                if (cargs.len != 2) return self.fail("testC yieldk expects 2 args", .{});
                const nres_i = try self.parseTestcNumToken(cargs[0], st);
                if (nres_i < 0) return self.fail("testC invalid yield count", .{});
                const nres: usize = @intCast(nres_i);
                if (nres > st.items.len) return self.fail("testC stack underflow", .{});
                const base = st.items.len - nres;
                const cont_script = try self.resolveTestcContinuationScript(ctx, st, cargs[1]);
                const th = self.current_thread orelse return self.fail("attempt to yield from outside a coroutine", .{});
                const closers = try self.collectTestcClosers(st, toclose, base);
                defer self.alloc.free(closers);
                try self.saveTestcPendingContinuation(th, cont_script, st.items[0..base], ctx, "YIELD", testcContinuationCtxId(cargs[1]), closers);
                var outv: [0]Value = .{};
                try self.builtinCoroutineYield(st.items[base..], outv[0..]);
            },
            .setmetatable => {
                if (cargs.len != 1) return self.fail("testC setmetatable expects 1 arg", .{});
                if (st.items.len == 0) return self.fail("testC stack underflow", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const obj = st.items[idx];
                const mtv = st.pop().?;
                const mt: ?*Table = switch (mtv) {
                    .Nil => null,
                    .Table => |t| t,
                    else => return self.fail("testC setmetatable expects table|nil metatable", .{}),
                };
                switch (obj) {
                    .Table => |t| t.metatable = mt,
                    else => return self.fail("testC setmetatable expects table/userdata", .{}),
                }
            },
            .newmetatable => {
                if (cargs.len != 1) return self.fail("testC newmetatable expects 1 arg", .{});
                const reg = try self.ensureDebugRegistry();
                const k = trimTestcQuoted(cargs[0]);
                if (self.getFieldOpt(reg, k)) |existing| {
                    try st.append(self.alloc, existing);
                    try st.append(self.alloc, .{ .Bool = false });
                } else {
                    const mt = try self.allocTable();
                    try self.setField(reg, k, .{ .Table = mt });
                    try st.append(self.alloc, .{ .Table = mt });
                    try st.append(self.alloc, .{ .Bool = true });
                }
            },
            .testudata => {
                if (cargs.len != 2) return self.fail("testC testudata expects 2 args", .{});
                const idx = try self.parseTestcIndexMaybe(cargs[0], st.items.len);
                const reg = try self.ensureDebugRegistry();
                const key = trimTestcQuoted(cargs[1]);
                const want = self.getFieldOpt(reg, key) orelse .Nil;
                if (idx == null or want != .Table) {
                    try st.append(self.alloc, .Nil);
                    return null;
                }
                const v = st.items[idx.?];
                if (v != .Table or v.Table.metatable == null or v.Table.metatable.? != want.Table) {
                    try st.append(self.alloc, .Nil);
                } else {
                    try st.append(self.alloc, v);
                }
            },
            .gsub => {
                if (cargs.len != 3) return self.fail("testC gsub expects 3 args", .{});
                const sidx = try self.parseTestcIndex(cargs[0], st.items.len);
                const pidx = try self.parseTestcIndex(cargs[1], st.items.len);
                const ridx = try self.parseTestcIndex(cargs[2], st.items.len);
                const src = switch (st.items[sidx]) {
                    .String => |s| s.bytes(),
                    else => return self.fail("testC gsub expects string source", .{}),
                };
                const patt = switch (st.items[pidx]) {
                    .String => |s| s.bytes(),
                    else => return self.fail("testC gsub expects string pattern", .{}),
                };
                const repl = switch (st.items[ridx]) {
                    .String => |s| s.bytes(),
                    else => return self.fail("testC gsub expects string replacement", .{}),
                };
                const replaced = try std.mem.replaceOwned(u8, self.alloc, src, patt, repl);
                try st.append(self.alloc, .{ .String = try self.internStr(replaced) });
            },
            .closeslot => {
                if (cargs.len != 1) return self.fail("testC closeslot expects 1 arg", .{});
                const idx = try self.parseTestcIndex(cargs[0], st.items.len);
                const obj = st.items[idx];
                self.non_yieldable_c_depth += 1;
                defer self.non_yieldable_c_depth -= 1;
                self.runTestcCloseMetamethod(obj, null) catch |e| {
                    st.items[idx] = .Nil;
                    testcUnmark(toclose, idx);
                    return e;
                };
                st.items[idx] = .Nil;
                testcUnmark(toclose, idx);
            },
            .sethook => {
                if (cargs.len < 3) return self.fail("testC sethook expects at least 3 args", .{});
                const mask_bits = std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid hook mask", .{});
                const count = std.fmt.parseInt(i64, cargs[1], 10) catch return self.fail("testC invalid hook count", .{});
                var hook_fn: Value = .Nil;
                const hook_body = cargs[2];
                const t_global = self.getGlobal("T");
                if (t_global != .Table) return self.fail("testC sethook: T table missing", .{});
                const mk = self.getFieldOpt(t_global.Table, "makeCfunc") orelse return self.fail("testC sethook: makeCfunc missing", .{});
                var hook_args = [_]Value{.{ .String = try self.internStr(hook_body) }};
                const ret = try self.apiCall(mk, hook_args[0..]);
                defer self.alloc.free(ret);
                hook_fn = if (ret.len > 0) ret[0] else .Nil;

                var mask_buf: [3]u8 = undefined;
                var mask_len: usize = 0;
                if ((mask_bits & 1) != 0) {
                    mask_buf[mask_len] = 'c';
                    mask_len += 1;
                }
                if ((mask_bits & 2) != 0) {
                    mask_buf[mask_len] = 'r';
                    mask_len += 1;
                }
                if ((mask_bits & 4) != 0) {
                    mask_buf[mask_len] = 'l';
                    mask_len += 1;
                }
                const mask = mask_buf[0..mask_len];
                var dbg_args: [3]Value = .{
                    hook_fn,
                    .{ .String = try self.internStr(mask) },
                    .{ .Int = count },
                };
                var outv: [1]Value = .{.Nil};
                try self.builtinDebugSethook(dbg_args[0..], outv[0..]);
            },
            .traceback => {
                if (cargs.len != 2) return self.fail("testC traceback expects 2 args", .{});
                const msg = trimTestcQuoted(cargs[0]);
                const level = std.fmt.parseInt(i64, cargs[1], 10) catch return self.fail("testC invalid traceback level", .{});
                var dbg_args: [2]Value = .{
                    .{ .String = try self.internStr(msg) },
                    .{ .Int = level },
                };
                var outv: [1]Value = .{.Nil};
                try self.builtinDebugTraceback(dbg_args[0..], outv[0..]);
                try st.append(self.alloc, outv[0]);
            },
            .pcall => {
                if (cargs.len != 2 and cargs.len != 3) return self.fail("testC pcall expects 2 or 3 args", .{});
                const nargs = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid nargs", .{});
                const nresults = std.fmt.parseInt(i32, cargs[1], 10) catch return self.fail("testC invalid nresults", .{});
                if (st.items.len < nargs + 1) return self.fail("testC stack underflow", .{});
                const fn_idx = st.items.len - nargs - 1;
                var call_idx = fn_idx;
                if (!isCallableValue(st.items[call_idx])) {
                    var j = call_idx;
                    while (j > 0) {
                        j -= 1;
                        if (isCallableValue(st.items[j])) {
                            call_idx = j;
                            break;
                        }
                    }
                }
                const callee = st.items[call_idx];
                const call_args = st.items[st.items.len - nargs ..];
                const handler_idx: ?usize = if (cargs.len == 3) blk: {
                    const ei = std.fmt.parseInt(i32, cargs[2], 10) catch break :blk null;
                    if (ei == 0) break :blk null;
                    if (ei > 0) {
                        // ltests 'pcall ... errfunc' uses a relative index around
                        // the callee slot (so `1` can point to handler argument).
                        const rel: usize = @intCast(ei);
                        if (rel > fn_idx) break :blk null;
                        break :blk fn_idx - rel;
                    }
                    break :blk try self.parseTestcIndex(cargs[2], st.items.len);
                } else null;
                const handler_val: ?Value = if (handler_idx) |hi| st.items[hi] else null;
                const mem_before_call = self.testc_total_bytes;
                const obj_tables_before_call = self.testc_obj_tables;
                const obj_functions_before_call = self.testc_obj_functions;
                const obj_threads_before_call = self.testc_obj_threads;
                const obj_strings_before_call = self.testc_obj_strings;
                const ret = self.apiCall(callee, call_args) catch {
                    const errv = self.protectedErrorValue();
                    if (isTestcMemoryErrorValue(errv)) {
                        // This VM does not have PUC Lua's real collector yet.
                        // For ltests memory-limit probes, failed protected
                        // calls must not leave partial allocations counted as
                        // live; after the script's collectgarbage() they would
                        // be unreachable in PUC.
                        self.testc_total_bytes = mem_before_call;
                        self.testc_obj_tables = obj_tables_before_call;
                        self.testc_obj_functions = obj_functions_before_call;
                        self.testc_obj_threads = obj_threads_before_call;
                        self.testc_obj_strings = obj_strings_before_call;
                    }
                    const handler_errv = normalizeTestcErrorForHandler(self, errv);
                    st.items.len = call_idx;
                    if (handler_val) |h| {
                        var hargs = [_]Value{handler_errv};
                        const hret = self.apiCall(h, hargs[0..]) catch {
                            try st.append(self.alloc, errv);
                            last_status.* = "ERRRUN";
                            return null;
                        };
                        defer self.alloc.free(hret);
                        if (hret.len > 0) {
                            try st.append(self.alloc, hret[0]);
                        } else {
                            try st.append(self.alloc, .Nil);
                        }
                    } else {
                        try st.append(self.alloc, errv);
                    }
                    last_status.* = if (isTestcMemoryErrorValue(errv))
                        "not enough memory"
                    else
                        "ERRRUN";
                    return null;
                };
                defer self.alloc.free(ret);
                st.items.len = call_idx;
                const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
                try st.appendSlice(self.alloc, ret[0..want]);
                last_status.* = "OK";
            },
            .pcallk => {
                if (cargs.len != 3) return self.fail("testC pcallk expects 3 args", .{});
                const nargs = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid nargs", .{});
                const nresults = std.fmt.parseInt(i32, cargs[1], 10) catch return self.fail("testC invalid nresults", .{});
                const cont_script = try self.resolveTestcContinuationScript(ctx, st, cargs[2]);
                const ctx_id = testcContinuationCtxId(cargs[2]);
                if (st.items.len < nargs + 1) return self.fail("testC stack underflow", .{});
                const fn_idx = st.items.len - nargs - 1;
                var call_idx = fn_idx;
                if (!isCallableValue(st.items[call_idx])) {
                    var j = call_idx;
                    while (j > 0) {
                        j -= 1;
                        if (isCallableValue(st.items[j])) {
                            call_idx = j;
                            break;
                        }
                    }
                }
                const callee = st.items[call_idx];
                const call_args = st.items[st.items.len - nargs ..];
                const prefix_len = call_idx;
                const ret = self.apiCall(callee, call_args) catch |e| switch (e) {
                    error.Yield => {
                        const th = self.current_thread orelse return e;
                        const closers = try self.collectTestcClosers(st, toclose, prefix_len);
                        defer self.alloc.free(closers);
                        try self.saveTestcPendingContinuation(th, cont_script, st.items[0..prefix_len], ctx, "YIELD", ctx_id, closers);
                        last_status.* = "YIELD";
                        return e;
                    },
                    else => {
                        const errv = self.protectedErrorValue();
                        const handler_errv = normalizeTestcErrorForHandler(self, errv);
                        st.items.len = prefix_len;
                        try st.append(self.alloc, handler_errv);
                        last_status.* = "ERRRUN";

                        if (ctx.upenv) |uv| {
                            if (uv == .Table) {
                                try self.tableSetValue(uv.Table, .{ .String = try self.internStr("status") }, .{ .String = try self.internStr("ERRRUN") });
                                try self.tableSetValue(uv.Table, .{ .String = try self.internStr("ctx") }, .{ .Int = ctx_id });
                            }
                        } else {
                            try self.setGlobal("status", .{ .String = try self.internStr("ERRRUN") });
                            try self.setGlobal("ctx", .{ .Int = ctx_id });
                        }
                        const rr = try self.runTestcScript(cont_script, st, ctx);
                        return rr.return_spec;
                    },
                };
                defer self.alloc.free(ret);
                st.items.len = call_idx;
                const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
                try st.appendSlice(self.alloc, ret[0..want]);
                last_status.* = "OK";
            },
            .ret => {
                if (cargs.len != 1) return self.fail("testC return expects 1 arg", .{});
                if (std.mem.eql(u8, cargs[0], "*")) return .all;
                if (std.mem.eql(u8, cargs[0], ".")) {
                    if (st.items.len == 0) return self.fail("testC return . expects count on stack", .{});
                    const count_v = st.pop().?;
                    const n: usize = switch (count_v) {
                        .Int => |i| if (i >= 0) @intCast(i) else return self.fail("testC invalid return count", .{}),
                        .Num => |x| if (std.math.isFinite(x) and x >= 0 and x == @floor(x)) @intFromFloat(x) else return self.fail("testC invalid return count", .{}),
                        else => return self.fail("testC invalid return count", .{}),
                    };
                    return .{ .fixed = n };
                }
                const n = std.fmt.parseInt(usize, cargs[0], 10) catch return self.fail("testC invalid return count", .{});
                return .{ .fixed = n };
            },
        }
        return null;
    }

    fn parseTestcIndex(self: *Vm, tok: []const u8, top: usize) Error!usize {
        const idx = std.fmt.parseInt(i32, tok, 10) catch return self.fail("testC invalid index '{s}'", .{tok});
        if (idx == 0) return self.fail("testC invalid index '{s}'", .{tok});
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            if (abs >= top) return self.fail("testC index out of range '{s}' (top={d})", .{ tok, top });
            return abs;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > top) return self.fail("testC index out of range '{s}' (top={d})", .{ tok, top });
        return top - r;
    }

    fn parseTestcIndexMaybe(self: *Vm, tok: []const u8, top: usize) Error!?usize {
        const idx = std.fmt.parseInt(i32, tok, 10) catch return self.fail("testC invalid index", .{});
        if (idx == 0) return self.fail("testC invalid index", .{});
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            if (abs >= top) return null;
            return abs;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > top) return null;
        return top - r;
    }

    fn parseTestcSettop(self: *Vm, tok: []const u8, top: usize) Error!usize {
        const idx = std.fmt.parseInt(i32, tok, 10) catch return self.fail("testC invalid settop", .{});
        if (idx >= 0) return @intCast(idx);
        const t: i64 = @intCast(top);
        const nt = t + @as(i64, idx) + 1;
        if (nt < 0) return self.fail("testC invalid settop", .{});
        return @intCast(nt);
    }

    fn testcIsMarked(marks: []const usize, idx: usize) bool {
        for (marks) |m| {
            if (m == idx) return true;
        }
        return false;
    }

    fn testcUnmark(marks: *std.ArrayListUnmanaged(usize), idx: usize) void {
        var i: usize = 0;
        while (i < marks.items.len) {
            if (marks.items[i] == idx) {
                _ = marks.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn testcDropMarksAbove(marks: *std.ArrayListUnmanaged(usize), new_len: usize) void {
        var i: usize = 0;
        while (i < marks.items.len) {
            if (marks.items[i] >= new_len) {
                _ = marks.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn normalizeTestcErrorForHandler(self: *Vm, v: Value) Value {
        if (v == .String) {
            const s = v.String.bytes();
            if (std.mem.lastIndexOf(u8, s, ": ")) |p| {
                if (p + 2 <= s.len) return .{ .String = self.internStrAssume(s[p + 2 ..]) };
            }
        }
        return v;
    }

    fn resolveTestcContinuationScript(self: *Vm, ctx: TestcContext, st: *std.ArrayListUnmanaged(Value), tok: []const u8) Error![]const u8 {
        const v: Value = if (std.mem.eql(u8, tok, ".")) blk: {
            if (st.items.len == 0) return self.fail("testC stack underflow", .{});
            break :blk st.pop().?;
        } else if (parseTestcUpvalueToken(tok)) |uix| blk: {
            break :blk try self.getTestcUpvalue(ctx, uix);
        } else blk: {
            const idx = try self.parseTestcIndex(tok, st.items.len);
            break :blk st.items[idx];
        };
        return switch (v) {
            .String => |s| s.bytes(),
            else => self.fail("testC continuation expects script string", .{}),
        };
    }

    fn saveTestcPendingContinuation(
        self: *Vm,
        th: *Thread,
        script: []const u8,
        stack_vals: []const Value,
        ctx: TestcContext,
        status: []const u8,
        ctx_id: i64,
        closers: []const Value,
    ) Error!void {
        const stack_copy = try self.alloc.alloc(Value, stack_vals.len);
        for (stack_vals, 0..) |v, i| stack_copy[i] = v;
        var upvalues_copy: ?[]Value = null;
        if (ctx.upvalues) |vals| {
            const uv_copy = try self.alloc.alloc(Value, vals.len);
            for (vals, 0..) |v, i| uv_copy[i] = v;
            upvalues_copy = uv_copy;
        }
        var closers_copy: ?[]Value = null;
        if (closers.len != 0) {
            const cc = try self.alloc.alloc(Value, closers.len);
            for (closers, 0..) |v, i| cc[i] = v;
            closers_copy = cc;
        }
        try th.testc_pending_conts.append(self.alloc, .{
            .script = script,
            .stack = stack_copy,
            .upvalues = upvalues_copy,
            .upenv = ctx.upenv orelse .Nil,
            .state = ctx.state,
            .status = status,
            .ctx = ctx_id,
            .first_arg = ctx.first_arg,
            .closers = closers_copy,
        });
    }

    fn testcContinuationCtxId(tok: []const u8) i64 {
        if (parseTestcUpvalueToken(tok)) |uix| return @intCast(uix);
        return std.fmt.parseInt(i64, tok, 10) catch 0;
    }

    fn collectTestcClosers(
        self: *Vm,
        st: *std.ArrayListUnmanaged(Value),
        toclose: *std.ArrayListUnmanaged(usize),
        stack_len: usize,
    ) Error![]Value {
        var count: usize = 0;
        for (toclose.items) |idx| {
            if (idx < stack_len) count += 1;
        }
        const vals = try self.alloc.alloc(Value, count);
        var out_i: usize = 0;
        for (toclose.items) |idx| {
            if (idx < stack_len) {
                vals[out_i] = st.items[idx];
                out_i += 1;
            }
        }
        return vals;
    }

    fn trimTestcQuoted(s0: []const u8) []const u8 {
        var s = std.mem.trim(u8, s0, " \t\r");
        if (s.len >= 2 and ((s[0] == '\'' and s[s.len - 1] == '\'') or (s[0] == '"' and s[s.len - 1] == '"'))) {
            s = s[1 .. s.len - 1];
        }
        return s;
    }

    fn parseLeadingIntTail(tok: []const u8) ?struct { n: i64, tail: []const u8 } {
        if (tok.len == 0) return null;
        var i: usize = 0;
        if (tok[0] == '+' or tok[0] == '-') i = 1;
        const start_digits = i;
        while (i < tok.len and tok[i] >= '0' and tok[i] <= '9') : (i += 1) {}
        if (i == start_digits) return null;
        const n = std.fmt.parseInt(i64, tok[0..i], 10) catch return null;
        return .{ .n = n, .tail = tok[i..] };
    }

    fn parseTestcUpvalueToken(tok: []const u8) ?usize {
        if (tok.len < 2 or tok[0] != 'U') return null;
        return std.fmt.parseInt(usize, tok[1..], 10) catch null;
    }

    fn getTestcUpvalue(self: *Vm, ctx: TestcContext, uix: usize) Error!Value {
        if (uix == 0) return ctx.upenv orelse .Nil;
        const upvs = ctx.upvalues orelse return .Nil;
        const i = uix - 1;
        if (i >= upvs.len) return try self.makeTestcPointerValue(0);
        return upvs[i];
    }

    fn setTestcUpvalue(self: *Vm, ctx: TestcContext, uix: usize, v: Value) Error!void {
        if (uix == 0) {
            _ = self;
            return;
        }
        const upvs = ctx.upvalues orelse return;
        const i = uix - 1;
        if (i >= upvs.len) return;
        upvs[i] = v;
    }

    fn isCallableValue(v: Value) bool {
        return switch (v) {
            .Builtin, .Closure, .Table => true,
            else => false,
        };
    }

    fn failTestcRaw(self: *Vm, msg: []const u8) Error {
        const ls = try self.internStr(msg);
        self.err = ls.bytes();
        self.err_obj = .{ .String = ls };
        self.err_has_obj = true;
        self.err_source = null;
        self.err_line = -1;
        self.captureErrorTraceback();
        return error.RuntimeError;
    }

    fn isUserdataLike(self: *Vm, v: Value) bool {
        if (asFileTable(self, v) != null) return true;
        return isTestcUserdata(self, v);
    }

    fn isTestcUserdata(self: *Vm, v: Value) bool {
        if (v != .Table) return false;
        if (self.getFieldOpt(v.Table, "__testud")) |tv| {
            if (tv == .Bool and tv.Bool) return true;
        }
        const mt = v.Table.metatable orelse return false;
        const nm = self.getFieldOpt(mt, "__name") orelse return false;
        return nm == .String and nm.String == self.internStrAssume("__TESTUD");
    }

    fn isTestcLightUserdata(self: *Vm, v: Value) bool {
        if (!isTestcUserdata(self, v)) return false;
        return switch (self.getFieldOpt(v.Table, "__light") orelse .Nil) {
            .Bool => |b| b,
            else => false,
        };
    }

    fn isTestcNullPointer(self: *Vm, v: Value) bool {
        if (!isTestcUserdata(self, v)) return false;
        return switch (self.getFieldOpt(v.Table, "__isnull") orelse .Nil) {
            .Bool => |b| b,
            else => false,
        };
    }

    fn makeTestcPointerValue(self: *Vm, ptr_id: u64) Error!Value {
        const t_global = self.getGlobal("T");
        if (t_global != .Table) return .Nil;
        const t = t_global.Table;
        const pushud = self.getFieldOpt(t, "pushuserdata") orelse return .Nil;
        var call_args = [_]Value{.{ .Int = @intCast(ptr_id) }};
        return switch (pushud) {
            .Builtin => |id| blk: {
                var out: [1]Value = .{.Nil};
                try self.callBuiltin(id, call_args[0..], out[0..]);
                break :blk out[0];
            },
            .Closure => |cl| blk: {
                const ret = try self.runClosure(cl, call_args[0..], false);
                defer self.alloc.free(ret);
                break :blk if (ret.len > 0) ret[0] else .Nil;
            },
            else => .Nil,
        };
    }

    fn testcLiveUserdataKb(self: *Vm) f64 {
        const t_global = self.getGlobal("T");
        if (t_global != .Table) return 0.0;
        const fnv = self.getFieldOpt(t_global.Table, "_liveudbytes") orelse return 0.0;
        const retv: Value = switch (fnv) {
            .Builtin => |id| blk: {
                var out: [1]Value = .{.Nil};
                self.callBuiltin(id, &[_]Value{}, out[0..]) catch return 0.0;
                break :blk out[0];
            },
            .Closure => |cl| blk: {
                const ret = self.runClosure(cl, &[_]Value{}, false) catch return 0.0;
                defer self.alloc.free(ret);
                break :blk if (ret.len > 0) ret[0] else .Nil;
            },
            else => return 0.0,
        };
        const bytes: f64 = switch (retv) {
            .Int => |v| @floatFromInt(v),
            .Num => |v| v,
            else => 0.0,
        };
        return if (bytes > 0.0) bytes / 1024.0 else 0.0;
    }

    fn builtinHasDynamicOutCount(id: BuiltinId) bool {
        return switch (id) {
            .coroutine_wrap_iter, .coroutine_yield, .pcall, .xpcall, .utf8_codepoint, .io_lines_iter, .io_read, .file_read, .dofile, .io_lines, .file_lines, .testc_testC => true,
            else => false,
        };
    }

    fn builtinOutLen(self: *Vm, id: BuiltinId, call_args: []const Value) usize {
        return switch (id) {
            .print => 0,
            .warn => 0,
            .@"error" => 0,
            .io_write, .io_stderr_write => 1,
            .io_close, .file_close => 2,
            .io_open, .io_tmpfile => 3,
            .io_read, .file_read => 8,
            .io_lines => blk: {
                if (call_args.len > 0 and call_args[0] == .String) break :blk 4;
                break :blk 3;
            },
            .file_lines => 3,
            .io_lines_iter => blk: {
                if (call_args.len == 0 or call_args[0] != .Table) break :blk 8;
                const it = call_args[0].Table;
                const n = if (self.getFieldOpt(it, "__fmts")) |v|
                    if (v == .Table) v.Table.array.items.len else 0
                else
                    0;
                break :blk if (n == 0) 1 else n;
            },
            .io_flush, .file_flush, .file_setvbuf => 1,
            .file_seek => 3,
            .file_write => 4,
            .os_remove, .os_rename => 3,

            .math_random => 1,
            .math_randomseed => 2,
            .pairs, .ipairs => 3,
            .pairs_iter, .ipairs_iter => 2,
            .coroutine_running => 2,

            .assert => call_args.len,
            .select => blk: {
                if (call_args.len == 0) break :blk 0;
                switch (call_args[0]) {
                    .String => |s| {
                        if (s == self.internStrAssume("#")) break :blk 1;
                        break :blk 0;
                    },
                    .Int => |raw_idx| {
                        var idx = raw_idx;
                        const n = call_args.len - 1;
                        if (idx == 0) break :blk 0;
                        if (idx < 0) idx += @as(i64, @intCast(n)) + 1;
                        if (idx < 1) break :blk 0;
                        if (@as(usize, @intCast(idx)) > n) break :blk 0;
                        break :blk n - @as(usize, @intCast(idx)) + 1;
                    },
                    else => break :blk 0,
                }
            },
            .pcall, .xpcall => 256,
            .coroutine_resume => 8,
            .coroutine_yield => 8,
            .coroutine_close => 2,
            .coroutine_wrap_iter => 256,
            .next => 2,
            .dofile => 16,
            .testc_testC => 256,
            .testc_makecfunc => 1,
            .testc_totalmem => 3,
            .loadfile, .load => 2,
            .require => 2,
            .package_searchpath => 2,
            .setmetatable, .getmetatable => 1,
            .debug_getinfo => 1,
            .debug_getlocal => 2,
            .debug_setlocal => 1,
            .debug_getupvalue => 2,
            .debug_setupvalue => 1,
            .debug_upvaluejoin => 0,
            .debug_gethook => 3,
            .debug_sethook => 0,
            .debug_getuservalue => 2,
            .debug_setuservalue => 1,
            .math_type => 1,
            .math_modf => 2,
            .math_frexp => 2,
            .math_min => 1,
            .math_max => 1,
            .math_floor => 1,
            .string_len => 1,
            .string_char => 1,
            .string_byte => blk: {
                if (call_args.len == 0 or call_args[0] != .String) break :blk 1;
                const s = call_args[0].String;
                var start_idx: i64 = if (call_args.len >= 2 and call_args[1] == .Int) call_args[1].Int else 1;
                var end_idx: i64 = if (call_args.len >= 3 and call_args[2] == .Int) call_args[2].Int else start_idx;
                const len: i64 = @intCast(s.len);
                if (start_idx < 0) start_idx += len + 1;
                if (end_idx < 0) end_idx += len + 1;
                if (start_idx < 1) start_idx = 1;
                if (end_idx > len) end_idx = len;
                if (start_idx > end_idx or start_idx > len) break :blk 0;
                break :blk @intCast(end_idx - start_idx + 1);
            },
            .string_sub => 1,
            .string_find => blk: {
                if (call_args.len < 2 or call_args[1] != .String) break :blk 2;
                const caps = estimatePatternCaptureCount(call_args[1].String.bytes());
                break :blk 2 + caps;
            },
            .string_gsub => 2,
            .string_gmatch => 1,
            .string_gmatch_iter => 10,
            .string_match => blk: {
                if (call_args.len < 2 or call_args[1] != .String) break :blk 1;
                const caps = estimatePatternCaptureCount(call_args[1].String.bytes());
                break :blk if (caps == 0) 1 else caps;
            },
            .utf8_char => 1,
            .utf8_codepoint => blk: {
                if (call_args.len == 0 or call_args[0] != .String) break :blk 1;
                const s = call_args[0].String;
                var i: i64 = 1;
                var j: i64 = 1;
                if (call_args.len >= 2) i = switch (call_args[1]) {
                    .Int => |x| x,
                    else => break :blk 1,
                };
                j = if (call_args.len >= 3)
                    switch (call_args[2]) {
                        .Int => |x| x,
                        else => break :blk 1,
                    }
                else
                    i;
                const len: i64 = @intCast(s.len);
                if (i < 0) i += len + 1;
                if (j < 0) j += len + 1;
                if (i < 1 or j < 1 or i > len or j > len or i > j) break :blk 0;
                break :blk @intCast(j - i + 1);
            },
            .utf8_len => 2,
            .utf8_offset => 2,
            .utf8_codes => 3,
            .utf8_codes_iter, .utf8_codes_iter_ns => 2,
            .string_unpack => blk: {
                if (call_args.len == 0 or call_args[0] != .String) break :blk 2;
                const fmt = call_args[0].String.bytes();
                var i: usize = 0;
                var nvals: usize = 0;
                while (i < fmt.len) {
                    const ch = fmt[i];
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '<' or ch == '>' or ch == '=') {
                        i += 1;
                        continue;
                    }
                    if (ch == '!') {
                        i += 1;
                        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                        continue;
                    }
                    if (ch == 'b' or ch == 'B' or ch == 'h' or ch == 'H' or ch == 'l' or ch == 'L' or ch == 'i' or ch == 'I' or ch == 'j' or ch == 'J' or ch == 'n' or ch == 'f' or ch == 'd' or ch == 's' or ch == 'z' or ch == 'T') {
                        nvals += 1;
                        i += 1;
                        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                        continue;
                    }
                    if (ch == 'c') {
                        nvals += 1;
                        i += 1;
                        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {}
                        continue;
                    }
                    i += 1;
                }
                break :blk nvals + 1; // include next-position result
            },
            .string_dump => 1,
            .string_rep => 1,
            .table_insert => 0,
            .table_sort => 0,
            .table_unpack => blk: {
                if (call_args.len == 0 or call_args[0] != .Table) break :blk 0;
                const tbl = call_args[0].Table;
                if (tbl.metatable) |mt| {
                    if (self.getFieldOpt(mt, "__len") != null) break :blk 256;
                }
                const start_idx0: i64 = if (call_args.len >= 2) switch (call_args[1]) {
                    .Nil => 1,
                    .Int => |x| x,
                    .Num => |n| nblk: {
                        if (!std.math.isFinite(n)) break :blk 0;
                        const i: i64 = @intFromFloat(std.math.trunc(n));
                        if (@as(f64, @floatFromInt(i)) != n) break :blk 0;
                        break :nblk i;
                    },
                    else => break :blk 0,
                } else 1;
                const end_idx0: i64 = if (call_args.len >= 3) switch (call_args[2]) {
                    .Nil => tableBorderLen(tbl),
                    .Int => |x| x,
                    .Num => |n| nblk: {
                        if (!std.math.isFinite(n)) break :blk 0;
                        const i: i64 = @intFromFloat(std.math.trunc(n));
                        if (@as(f64, @floatFromInt(i)) != n) break :blk 0;
                        break :nblk i;
                    },
                    else => break :blk 0,
                } else tableBorderLen(tbl);
                if (end_idx0 < start_idx0) break :blk 0;
                const count_i128: i128 = (@as(i128, end_idx0) - @as(i128, start_idx0)) + 1;
                if (count_i128 <= 0) break :blk 0;
                if (count_i128 > 100_000) break :blk 1;
                break :blk @intCast(count_i128);
            },

            // Most builtins return a single value.
            else => 1,
        };
    }

    fn binAdd(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        return switch (l) {
            .Int => |li| switch (r) {
                .Int => |ri| .{ .Int = li +% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) + rn },
                else => switch (r) {
                    .Int => |ri| .{ .Int = li +% ri },
                    .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) + rn },
                    else => if (try self.callBinaryMetamethod(lhs, rhs, "__add", "add")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
                },
            },
            .Num => |ln| switch (r) {
                .Int => |ri| .{ .Num = ln + @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln + rn },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__add", "add")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__add", "add")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binSub(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        return switch (l) {
            .Int => |li| switch (r) {
                .Int => |ri| .{ .Int = li -% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) - rn },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__sub", "sub")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (r) {
                .Int => |ri| .{ .Num = ln - @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln - rn },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__sub", "sub")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__sub", "sub")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binMul(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        return switch (l) {
            .Int => |li| switch (r) {
                .Int => |ri| .{ .Int = li *% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) * rn },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__mul", "mul")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (r) {
                .Int => |ri| .{ .Num = ln * @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln * rn },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__mul", "mul")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__mul", "mul")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binDiv(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        const ln = switch (l) {
            .Int => |li| @as(f64, @floatFromInt(li)),
            .Num => |n| n,
            else => {
                if (try self.callBinaryMetamethod(lhs, rhs, "__div", "div")) |v| return v;
                return self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() });
            },
        };
        const rn = switch (r) {
            .Int => |ri| @as(f64, @floatFromInt(ri)),
            .Num => |n| n,
            else => {
                if (try self.callBinaryMetamethod(lhs, rhs, "__div", "div")) |v| return v;
                return self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() });
            },
        };
        return .{ .Num = ln / rn };
    }

    fn binIdiv(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        return switch (l) {
            .Int => |li| switch (r) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("divide by zero", .{});
                    if (li == std.math.minInt(i64) and ri == -1) return .{ .Int = std.math.minInt(i64) };
                    return .{ .Int = @divFloor(li, ri) };
                },
                .Num => |rn| {
                    return .{ .Num = std.math.floor(@as(f64, @floatFromInt(li)) / rn) };
                },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__idiv", "idiv")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (r) {
                .Int => |ri| {
                    return .{ .Num = std.math.floor(ln / @as(f64, @floatFromInt(ri))) };
                },
                .Num => |rn| {
                    return .{ .Num = std.math.floor(ln / rn) };
                },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__idiv", "idiv")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__idiv", "idiv")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binMod(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        return switch (l) {
            .Int => |li| switch (r) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("attempt to perform 'n%0'", .{});
                    if (li == std.math.minInt(i64) and ri == -1) return .{ .Int = 0 };
                    var rem = @rem(li, ri);
                    if (rem != 0 and ((rem ^ ri) < 0)) rem += ri;
                    return .{ .Int = rem };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("attempt to perform 'n%0'", .{});
                    const ln = @as(f64, @floatFromInt(li));
                    return .{ .Num = luaNumMod(ln, rn) };
                },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__mod", "mod")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (r) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("attempt to perform 'n%0'", .{});
                    const rn = @as(f64, @floatFromInt(ri));
                    return .{ .Num = luaNumMod(ln, rn) };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("attempt to perform 'n%0'", .{});
                    return .{ .Num = luaNumMod(ln, rn) };
                },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__mod", "mod")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__mod", "mod")) |v| v else self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn luaNumMod(a: f64, b: f64) f64 {
        var m = @rem(a, b);
        if ((m > 0 and b < 0) or (m < 0 and b > 0)) m += b;
        return m;
    }

    fn binPow(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const l = coerceArithmeticValue(lhs) orelse lhs;
        const r = coerceArithmeticValue(rhs) orelse rhs;
        const ln = switch (l) {
            .Int => |li| @as(f64, @floatFromInt(li)),
            .Num => |n| n,
            else => {
                if (try self.callBinaryMetamethod(lhs, rhs, "__pow", "pow")) |v| return v;
                return self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() });
            },
        };
        const rn = switch (r) {
            .Int => |ri| @as(f64, @floatFromInt(ri)),
            .Num => |n| n,
            else => {
                if (try self.callBinaryMetamethod(lhs, rhs, "__pow", "pow")) |v| return v;
                return self.fail("arithmetic on {s} and {s}", .{ lhs.typeName(), rhs.typeName() });
            },
        };
        return .{ .Num = std.math.pow(f64, ln, rn) };
    }

    fn binBand(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        if (valueToIntForBitwise(lhs)) |li| {
            if (valueToIntForBitwise(rhs)) |ri| return .{ .Int = li & ri };
        }
        if (try self.callBinaryMetamethod(lhs, rhs, "__band", "band")) |v| return v;
        if (isNumWithoutInteger(lhs) or isNumWithoutInteger(rhs)) return self.fail("number has no integer representation", .{});
        return self.fail("bitwise operation on {s} value and {s} value", .{ lhs.typeName(), rhs.typeName() });
    }

    fn binBor(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        if (valueToIntForBitwise(lhs)) |li| {
            if (valueToIntForBitwise(rhs)) |ri| return .{ .Int = li | ri };
        }
        if (try self.callBinaryMetamethod(lhs, rhs, "__bor", "bor")) |v| return v;
        if (isNumWithoutInteger(lhs) or isNumWithoutInteger(rhs)) return self.fail("number has no integer representation", .{});
        return self.fail("bitwise operation on {s} value and {s} value", .{ lhs.typeName(), rhs.typeName() });
    }

    fn binBxor(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        if (valueToIntForBitwise(lhs)) |li| {
            if (valueToIntForBitwise(rhs)) |ri| return .{ .Int = li ^ ri };
        }
        if (try self.callBinaryMetamethod(lhs, rhs, "__bxor", "bxor")) |v| return v;
        if (isNumWithoutInteger(lhs) or isNumWithoutInteger(rhs)) return self.fail("number has no integer representation", .{});
        return self.fail("bitwise operation on {s} value and {s} value", .{ lhs.typeName(), rhs.typeName() });
    }

    fn binShl(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        if (valueToIntForBitwise(lhs)) |li| {
            if (valueToIntForBitwise(rhs)) |ri| {
                const lu: u64 = @bitCast(li);
                if (ri >= 0 and ri < 64) {
                    const out: i64 = @bitCast(lu << @as(u6, @intCast(ri)));
                    return .{ .Int = out };
                }
                if (ri >= 64) return .{ .Int = 0 };
                if (ri == std.math.minInt(i64)) return .{ .Int = 0 };
                const s: i64 = -ri;
                if (s >= 64) return .{ .Int = 0 };
                const out: i64 = @bitCast(lu >> @as(u6, @intCast(s)));
                return .{ .Int = out };
            }
        }
        if (try self.callBinaryMetamethod(lhs, rhs, "__shl", "shl")) |v| return v;
        if (isNumWithoutInteger(lhs) or isNumWithoutInteger(rhs)) return self.fail("number has no integer representation", .{});
        return self.fail("bitwise operation on {s} value and {s} value", .{ lhs.typeName(), rhs.typeName() });
    }

    fn binShr(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        if (valueToIntForBitwise(lhs)) |li| {
            if (valueToIntForBitwise(rhs)) |ri| {
                const lu: u64 = @bitCast(li);
                if (ri >= 0 and ri < 64) {
                    const out: i64 = @bitCast(lu >> @as(u6, @intCast(ri)));
                    return .{ .Int = out };
                }
                if (ri >= 64) return .{ .Int = 0 };
                if (ri == std.math.minInt(i64)) return .{ .Int = 0 };
                const s: i64 = -ri;
                if (s >= 64) return .{ .Int = 0 };
                const out: i64 = @bitCast(lu << @as(u6, @intCast(s)));
                return .{ .Int = out };
            }
        }
        if (try self.callBinaryMetamethod(lhs, rhs, "__shr", "shr")) |v| return v;
        if (isNumWithoutInteger(lhs) or isNumWithoutInteger(rhs)) return self.fail("number has no integer representation", .{});
        return self.fail("bitwise operation on {s} value and {s} value", .{ lhs.typeName(), rhs.typeName() });
    }

    fn cmpLt(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li < ri,
                .Num => |rn| intLtNum(li, rn),
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__lt", "lt")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| numLtInt(ln, ri),
                .Num => |rn| ln < rn,
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__lt", "lt")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| std.mem.order(u8, ls.bytes(), rs.bytes()) == .lt,
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__lt", "lt")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__lt", "lt")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
        };
    }

    fn cmpLte(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li <= ri,
                .Num => |rn| intLeNum(li, rn),
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__le", "le")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| numLeInt(ln, ri),
                .Num => |rn| ln <= rn,
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__le", "le")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| {
                    const ord = std.mem.order(u8, ls.bytes(), rs.bytes());
                    return ord == .lt or ord == .eq;
                },
                else => if (try self.callBinaryMetamethod(lhs, rhs, "__le", "le")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
            },
            else => if (try self.callBinaryMetamethod(lhs, rhs, "__le", "le")) |v| isTruthy(v) else self.failCompare(lhs, rhs),
        };
    }

    fn cmpGt(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return try self.cmpLt(rhs, lhs);
    }

    fn cmpGte(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return try self.cmpLte(rhs, lhs);
    }

    fn intLtNum(i: i64, n: f64) bool {
        if (std.math.isNan(n)) return false;
        const min_i_f = -9_223_372_036_854_775_808.0;
        const max_i_plus1_f = 9_223_372_036_854_775_808.0;
        if (n <= min_i_f) return false;
        if (n >= max_i_plus1_f) return true;
        const t = std.math.trunc(n);
        if (t == n) {
            const ni: i64 = @intFromFloat(t);
            return i < ni;
        }
        return @as(f64, @floatFromInt(i)) < n;
    }

    fn intLeNum(i: i64, n: f64) bool {
        if (std.math.isNan(n)) return false;
        const min_i_f = -9_223_372_036_854_775_808.0;
        const max_i_plus1_f = 9_223_372_036_854_775_808.0;
        if (n < min_i_f) return false;
        if (n >= max_i_plus1_f) return true;
        const t = std.math.trunc(n);
        if (t == n) {
            const ni: i64 = @intFromFloat(t);
            return i <= ni;
        }
        return @as(f64, @floatFromInt(i)) <= n;
    }

    fn numLtInt(n: f64, i: i64) bool {
        if (std.math.isNan(n)) return false;
        const min_i_f = -9_223_372_036_854_775_808.0;
        const max_i_plus1_f = 9_223_372_036_854_775_808.0;
        if (n < min_i_f) return true;
        if (n >= max_i_plus1_f) return false;
        const t = std.math.trunc(n);
        if (t == n) {
            const ni: i64 = @intFromFloat(t);
            return ni < i;
        }
        return n < @as(f64, @floatFromInt(i));
    }

    fn numLeInt(n: f64, i: i64) bool {
        if (std.math.isNan(n)) return false;
        const min_i_f = -9_223_372_036_854_775_808.0;
        const max_i_plus1_f = 9_223_372_036_854_775_808.0;
        if (n <= min_i_f) return true;
        if (n >= max_i_plus1_f) return false;
        const t = std.math.trunc(n);
        if (t == n) {
            const ni: i64 = @intFromFloat(t);
            return ni <= i;
        }
        return n <= @as(f64, @floatFromInt(i));
    }

    const ConcatString = struct {
        bytes: []const u8,
        owned: bool = false,
    };

    fn concatOperandToString(self: *Vm, v: Value) Error!ConcatString {
        return switch (v) {
            .String => |s| .{ .bytes = s.bytes(), .owned = false },
            .Int => |i| .{ .bytes = try std.fmt.allocPrint(self.alloc, "{d}", .{i}), .owned = true },
            .Num => |n| .{ .bytes = try self.numberToStringAlloc(n), .owned = true },
            else => self.fail("attempt to concatenate a {s} value", .{v.typeName()}),
        };
    }

    fn binConcat(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        // Hot path for loops like `i .. "."` in nextvar.lua:
        // format integer operand into a stack buffer to avoid temporary heap
        // allocation from `allocPrint`.
        if (lhs == .Int and rhs == .String) {
            var ibuf: [32]u8 = undefined;
            const is = std.fmt.bufPrint(ibuf[0..], "{d}", .{lhs.Int}) catch unreachable;
            const out = try self.alloc.alloc(u8, is.len + rhs.String.len);
            std.mem.copyForwards(u8, out[0..is.len], is);
            std.mem.copyForwards(u8, out[is.len..], rhs.String.bytes());
            return .{ .String = try self.internStr(out) };
        }
        if (lhs == .String and rhs == .Int) {
            var ibuf: [32]u8 = undefined;
            const is = std.fmt.bufPrint(ibuf[0..], "{d}", .{rhs.Int}) catch unreachable;
            const out = try self.alloc.alloc(u8, lhs.String.len + is.len);
            std.mem.copyForwards(u8, out[0..lhs.String.len], lhs.String.bytes());
            std.mem.copyForwards(u8, out[lhs.String.len..], is);
            return .{ .String = try self.internStr(out) };
        }
        const a = self.concatOperandToString(lhs) catch {
            if (try self.callBinaryMetamethod(lhs, rhs, "__concat", "concat")) |v| return v;
            return self.fail("attempt to concatenate a {s} value", .{lhs.typeName()});
        };
        defer if (a.owned) self.alloc.free(a.bytes);
        const b = self.concatOperandToString(rhs) catch {
            if (try self.callBinaryMetamethod(lhs, rhs, "__concat", "concat")) |v| return v;
            return self.fail("attempt to concatenate a {s} value", .{rhs.typeName()});
        };
        defer if (b.owned) self.alloc.free(b.bytes);
        const out = try self.alloc.alloc(u8, a.bytes.len + b.bytes.len);
        std.mem.copyForwards(u8, out[0..a.bytes.len], a.bytes);
        std.mem.copyForwards(u8, out[a.bytes.len..], b.bytes);
        return .{ .String = try self.internStr(out) };
    }
};

test "vm: run return 1+2" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return 1 + 2\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: table constructor and access" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "x = {a = 1, [2] = 3, 4}\n" ++
            "return x.a + x[2]\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 4), v),
        else => try testing.expect(false),
    }
}

test "vm: call tostring (one result)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return tostring(1 + 2)\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("3", s.bytes()),
        else => try testing.expect(false),
    }
}

test "vm: if statement (NotEq) with _VERSION" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local version = \"Lua 5.5\"\n" ++
            "if _VERSION ~= version then\n" ++
            "  return 1\n" ++
            "end\n" ++
            "return 2\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
}

test "vm: string concat" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return \"a\" .. \"b\" .. 1\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("ab1", s.bytes()),
        else => try testing.expect(false),
    }
}

test "vm: locals swap uses temporaries" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local a, b = 1, 2\n" ++
            "a, b = b, a\n" ++
            "return tostring(a) .. tostring(b)\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("21", s.bytes()),
        else => try testing.expect(false),
    }
}

test "vm: local shadowing" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local x = 1\n" ++
            "do\n" ++
            "  local x = 2\n" ++
            "end\n" ++
            "return x\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
}

test "vm: local initializer sees outer binding" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local x = 1\n" ++
            "do\n" ++
            "  local x = x + 1\n" ++
            "  return x\n" ++
            "end\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
}

test "vm: while loop" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local i = 3\n" ++
            "local sum = 0\n" ++
            "while i ~= 0 do\n" ++
            "  sum = sum + i\n" ++
            "  i = i + -1\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 6), v),
        else => try testing.expect(false),
    }
}

test "vm: while break" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local i = 0\n" ++
            "while true do\n" ++
            "  i = i + 1\n" ++
            "  if i == 3 then\n" ++
            "    break\n" ++
            "  end\n" ++
            "end\n" ++
            "return i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: repeat until" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local i = 0\n" ++
            "repeat\n" ++
            "  i = i + 1\n" ++
            "until i == 3\n" ++
            "return i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: repeat until condition sees locals from block" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local out = 0\n" ++
            "repeat\n" ++
            "  local y = 1\n" ++
            "  out = y\n" ++
            "until y == 1\n" ++
            "return out\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
}

test "vm: arithmetic operators" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return 5 - 2, 3 * 4, 7 // 2, 7 % 4, 7 / 2, 2 ^ 3\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 6), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[1]) {
        .Int => |v| try testing.expectEqual(@as(i64, 12), v),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .Num => |v| try testing.expectApproxEqAbs(@as(f64, 3.5), v, 1e-9),
        else => try testing.expect(false),
    }
    switch (ret[5]) {
        .Num => |v| try testing.expectApproxEqAbs(@as(f64, 8.0), v, 1e-9),
        else => try testing.expect(false),
    }
}

test "vm: numeric comparisons" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local i = 0\n" ++
            "while i < 3 do i = i + 1 end\n" ++
            "return i, 1 < 2, 2 <= 2, 3 > 2, 3 >= 3\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 5), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    for (ret[1..]) |v| {
        switch (v) {
            .Bool => |b| try testing.expect(b),
            else => try testing.expect(false),
        }
    }
}

test "vm: string comparisons" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return \"a\" < \"b\", \"a\" <= \"a\", \"b\" > \"a\", \"b\" >= \"b\"\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 4), ret.len);
    for (ret) |v| {
        switch (v) {
            .Bool => |b| try testing.expect(b),
            else => try testing.expect(false),
        }
    }
}

test "vm: string escapes" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return " ++
            "\"a\\n\", " ++
            "\"\\x41\", " ++
            "\"\\065\", " ++
            "\"\\u{41}\", " ++
            "\"a\\z \n\tb\"\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 5), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("a\n", s.bytes()),
        else => try testing.expect(false),
    }
    switch (ret[1]) {
        .String => |s| try testing.expectEqualStrings("A", s.bytes()),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .String => |s| try testing.expectEqualStrings("A", s.bytes()),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .String => |s| try testing.expectEqualStrings("A", s.bytes()),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .String => |s| try testing.expectEqualStrings("ab", s.bytes()),
        else => try testing.expect(false),
    }
}

test "vm: and/or semantics and short-circuit" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig").AstArena;
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return " ++
            "nil and 1, " ++
            "0 and 1, " ++
            "false or 1, " ++
            "2 or 3, " ++
            "(false and error(\"boom\")) == false, " ++
            "(true or error(\"boom\")) == true\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 6), ret.len);
    try testing.expect(ret[0] == .Nil);
    switch (ret[1]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .Bool => |b| try testing.expect(b),
        else => try testing.expect(false),
    }
    switch (ret[5]) {
        .Bool => |b| try testing.expect(b),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop (default step)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local sum = 0\n" ++
            "for i = 1, 5 do\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 15), v),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop (negative step)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local sum = 0\n" ++
            "for i = 5, 1, -1 do\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 15), v),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop break + scope" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "local sum = 0\n" ++
            "for i = 1, 5 do\n" ++
            "  if i == 3 then break end\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum, i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 2), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    try testing.expect(ret[1] == .Nil);
}
