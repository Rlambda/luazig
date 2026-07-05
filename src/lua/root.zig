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
    pub const lower_ir = @import("lower_ir.zig");
    pub const bc_vm = @import("bc_vm.zig");
    pub const testc = @import("testc.zig");
    pub const ltable = @import("ltable.zig");
};

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
