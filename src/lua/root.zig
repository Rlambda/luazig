pub const api = @import("api.zig");
pub const c_api = @import("c_api.zig");

// Stable embedding surface starts here. Parser/IR/VM modules are intentionally
// grouped under `internal` so users do not treat them as supported API.
pub const State = api.State;
pub const ApiError = api.ApiError;
pub const Status = api.Status;
pub const Type = api.Type;

pub const internal = struct {
    pub const Diag = @import("diag.zig").Diag;
    pub const Source = @import("source.zig").Source;
    pub const Token = @import("token.zig").Token;
    pub const TokenKind = @import("token.zig").TokenKind;
    pub const Lexer = @import("lexer.zig").Lexer;
    pub const Parser = @import("parser.zig").Parser;
    pub const ast = @import("ast.zig");
    pub const ir = @import("ir.zig");
    pub const codegen = @import("codegen.zig");
    pub const vm = @import("vm.zig");
    pub const bytecode = @import("bytecode.zig");
    pub const codegen_bc = @import("codegen_bc.zig");
    pub const testc = @import("testc.zig");
    pub const ltable = @import("ltable.zig");
};

// C API export retention.
//
// Zig's module system compiles `c_api.zig` as a separate compilation unit.
// The linker's dead-code elimination removes `export fn` symbols from that
// unit if nothing in the consuming root references them — even with
// `-rdynamic`, the symbols are dropped before the dynamic-symbol pass runs.
//
// PUC Lua solves this with `-Wl,-E` (`--export-dynamic`) because the lua
// interpreter binary itself contains the C API (linked from the same .o
// files as liblua). Our c_api.zig lives in a module and is never called
// directly from Zig, so we must anchor every export explicitly.
//
// This `comptime` block takes the address of each exported C API function,
// making it a live root for the linker's reachability analysis. The symbol
// then survives into the executable's dynamic symbol table, where dlopen'd
// C extensions (.so) can resolve it.
//
// Adding a new `export fn` in c_api.zig? Add it here too.
comptime {
    // State lifecycle
    _ = &c_api.luaL_newstate;
    _ = &c_api.lua_close;
    // Stack manipulation
    _ = &c_api.lua_gettop;
    _ = &c_api.lua_settop;
    _ = &c_api.lua_pop;
    _ = &c_api.lua_rotate;
    _ = &c_api.lua_copy;
    _ = &c_api.lua_insert;
    _ = &c_api.lua_remove;
    // Push functions
    _ = &c_api.lua_pushnil;
    _ = &c_api.lua_pushboolean;
    _ = &c_api.lua_pushinteger;
    _ = &c_api.lua_pushnumber;
    _ = &c_api.lua_pushlstring;
    _ = &c_api.lua_pushstring;
    _ = &c_api.lua_pushliteral;
    _ = &c_api.lua_pushvalue;
    _ = &c_api.lua_pushcclosure;
    _ = &c_api.lua_pushcfunction;
    _ = &c_api.lua_pushfstring;
    _ = &c_api.lua_pushexternalstring;
    // Get functions
    _ = &c_api.lua_type;
    _ = &c_api.lua_toboolean;
    _ = &c_api.lua_tointegerx;
    _ = &c_api.lua_tonumberx;
    // Table functions
    _ = &c_api.lua_createtable;
    _ = &c_api.lua_setglobal;
    _ = &c_api.lua_getglobal;
    _ = &c_api.lua_setfield;
    _ = &c_api.lua_getfield;
    _ = &c_api.lua_rawset;
    _ = &c_api.lua_rawget;
    _ = &c_api.lua_next;
    // Call / error
    _ = &c_api.lua_call;
    _ = &c_api.lua_callk;
    _ = &c_api.lua_pcallk;
    _ = &c_api.lua_error;
    // Allocator
    _ = &c_api.lua_getallocf;
    // Auxlib
    _ = &c_api.luaL_checklstring;
    _ = &c_api.luaL_checkversion;
    _ = &c_api.luaL_checkversion_;
    _ = &c_api.luaL_newlib;
    _ = &c_api.luaL_setfuncs;
    _ = &c_api.luaL_ref;
    _ = &c_api.luaL_loadbufferx;
    _ = &c_api.luaL_loadfilex;
}

test {
    _ = State;
    _ = ApiError;
    _ = Status;
    _ = Type;
    _ = api;
    _ = c_api;
    _ = internal;
    _ = internal.ltable;
}
