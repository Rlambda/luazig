const std = @import("std");

const Diag = @import("diag.zig").Diag;
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;

pub const Parser = struct {
    lex: *Lexer,
    cur: Token,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    pub fn init(lex: *Lexer) !Parser {
        var p: Parser = .{
            .lex = lex,
            .cur = undefined,
        };
        p.cur = try lex.next();
        return p;
    }

    pub fn diagString(self: *Parser) []const u8 {
        const d = self.diag orelse return self.lex.diagString();
        return d.bufFormat(self.diag_buf[0..]);
    }

    fn setDiag(self: *Parser, msg: []const u8) void {
        self.diag = .{
            .source_name = self.lex.source.name,
            .line = self.cur.line,
            .col = self.cur.col,
            .msg = msg,
        };
    }

    fn advance(self: *Parser) !void {
        self.cur = try self.lex.next();
    }

    pub fn parseChunk(self: *Parser) !void {
        // Parse-only / shallow checker:
        // - balance (), [], {}
        // - ensure block delimiters are paired (function/if/do/for/while/end, repeat/until)
        //
        // This is intentionally conservative and will be replaced by a real Lua parser.
        var delims: [256]TokenKind = undefined;
        var delims_len: usize = 0;

        var blocks: [256]TokenKind = undefined;
        var blocks_len: usize = 0;

        while (true) {
            const k = self.cur.kind;
            switch (k) {
                .LParen => {
                    if (delims_len >= delims.len) {
                        self.setDiag("delimiter nesting too deep");
                        return error.SyntaxError;
                    }
                    delims[delims_len] = .RParen;
                    delims_len += 1;
                },
                .LBracket => {
                    if (delims_len >= delims.len) {
                        self.setDiag("delimiter nesting too deep");
                        return error.SyntaxError;
                    }
                    delims[delims_len] = .RBracket;
                    delims_len += 1;
                },
                .LBrace => {
                    if (delims_len >= delims.len) {
                        self.setDiag("delimiter nesting too deep");
                        return error.SyntaxError;
                    }
                    delims[delims_len] = .RBrace;
                    delims_len += 1;
                },

                .RParen, .RBracket, .RBrace => {
                    if (delims_len == 0) {
                        self.setDiag("unexpected closing delimiter");
                        return error.SyntaxError;
                    }
                    delims_len -= 1;
                    const want = delims[delims_len];
                    if (want != k) {
                        self.setDiag("mismatched closing delimiter");
                        return error.SyntaxError;
                    }
                },

                // Note: `for` and `while` blocks start at the `do` token, so
                // we only track `.Do` here to avoid double-counting.
                .Function, .Do, .If => {
                    if (blocks_len >= blocks.len) {
                        self.setDiag("block nesting too deep");
                        return error.SyntaxError;
                    }
                    blocks[blocks_len] = .End;
                    blocks_len += 1;
                },
                .Repeat => {
                    if (blocks_len >= blocks.len) {
                        self.setDiag("block nesting too deep");
                        return error.SyntaxError;
                    }
                    blocks[blocks_len] = .Until;
                    blocks_len += 1;
                },

                .End => {
                    if (blocks_len == 0 or blocks[blocks_len - 1] != .End) {
                        self.setDiag("unexpected 'end'");
                        return error.SyntaxError;
                    }
                    blocks_len -= 1;
                },
                .Until => {
                    if (blocks_len == 0 or blocks[blocks_len - 1] != .Until) {
                        self.setDiag("unexpected 'until'");
                        return error.SyntaxError;
                    }
                    blocks_len -= 1;
                },

                .Eof => break,
                else => {},
            }

            try self.advance();
        }

        if (delims_len != 0) {
            self.setDiag("unfinished delimiter");
            return error.SyntaxError;
        }
        if (blocks_len != 0) {
            self.setDiag("unfinished block");
            return error.SyntaxError;
        }
    }
};

test "parser balances blocks" {
    const src = @import("source.zig").Source{ .name = "<test>", .bytes = "do local x = 1 end" };
    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);
    try p.parseChunk();
}
