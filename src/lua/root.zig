pub const Diag = @import("diag.zig").Diag;
pub const Source = @import("source.zig").Source;
pub const Token = @import("token.zig").Token;
pub const TokenKind = @import("token.zig").TokenKind;
pub const Lexer = @import("lexer.zig").Lexer;
pub const Parser = @import("parser.zig").Parser;
pub const ast = @import("ast.zig");
pub const ir = @import("ir.zig");

test {
    _ = Diag;
    _ = Source;
    _ = Token;
    _ = TokenKind;
    _ = Lexer;
    _ = Parser;
    _ = ast;
    _ = ir;
}
