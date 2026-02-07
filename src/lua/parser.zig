const std = @import("std");

const Diag = @import("diag.zig").Diag;
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;

pub const Parser = struct {
    lex: *Lexer,
    cur: Token,
    la: Token,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    const ParseError = error{SyntaxError};

    pub fn init(lex: *Lexer) ParseError!Parser {
        var p: Parser = .{ .lex = lex, .cur = undefined, .la = undefined };
        p.cur = try lex.next();
        p.la = try lex.next();
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

    fn advance(self: *Parser) ParseError!void {
        self.cur = self.la;
        self.la = try self.lex.next();
    }

    fn match(self: *Parser, k: TokenKind) ParseError!bool {
        if (self.cur.kind != k) return false;
        try self.advance();
        return true;
    }

    fn expect(self: *Parser, k: TokenKind, msg: []const u8) ParseError!void {
        if (self.cur.kind != k) {
            self.setDiag(msg);
            return error.SyntaxError;
        }
        try self.advance();
    }

    fn expectName(self: *Parser, msg: []const u8) ParseError!Token {
        if (self.cur.kind != .Name) {
            self.setDiag(msg);
            return error.SyntaxError;
        }
        const t = self.cur;
        try self.advance();
        return t;
    }

    fn isBlockFollow(k: TokenKind) bool {
        return switch (k) {
            .End, .Else, .ElseIf, .Until, .Eof => true,
            else => false,
        };
    }

    fn parseBlock(self: *Parser) ParseError!void {
        while (!isBlockFollow(self.cur.kind)) {
            try self.parseStat();
            while (try self.match(.Semicolon)) {}
        }
    }

    pub fn parseChunk(self: *Parser) ParseError!void {
        try self.parseBlock();
        try self.expect(.Eof, "expected end of file");
    }

    fn parseStat(self: *Parser) ParseError!void {
        switch (self.cur.kind) {
            .If => return self.parseIfStat(),
            .While => return self.parseWhileStat(),
            .Do => return self.parseDoStat(),
            .For => return self.parseForStat(),
            .Repeat => return self.parseRepeatStat(),
            .Function => return self.parseFuncStat(),
            .Local => return self.parseLocalStat(),
            .Global => return self.parseGlobalStatFunc(),
            .DbColon => return self.parseLabelStat(),
            .Return => return self.parseReturnStat(),
            .Break => {
                try self.advance();
                return;
            },
            .Goto => return self.parseGotoStat(),
            else => return self.parseExprStat(),
        }
    }

    fn parseIfStat(self: *Parser) ParseError!void {
        try self.expect(.If, "expected 'if'");
        try self.parseExp(1);
        try self.expect(.Then, "expected 'then'");
        try self.parseBlock();
        while (self.cur.kind == .ElseIf) {
            try self.advance();
            try self.parseExp(1);
            try self.expect(.Then, "expected 'then'");
            try self.parseBlock();
        }
        if (try self.match(.Else)) {
            try self.parseBlock();
        }
        try self.expect(.End, "expected 'end'");
    }

    fn parseWhileStat(self: *Parser) ParseError!void {
        try self.expect(.While, "expected 'while'");
        try self.parseExp(1);
        try self.expect(.Do, "expected 'do'");
        try self.parseBlock();
        try self.expect(.End, "expected 'end'");
    }

    fn parseDoStat(self: *Parser) ParseError!void {
        try self.expect(.Do, "expected 'do'");
        try self.parseBlock();
        try self.expect(.End, "expected 'end'");
    }

    fn parseRepeatStat(self: *Parser) ParseError!void {
        try self.expect(.Repeat, "expected 'repeat'");
        try self.parseBlock();
        try self.expect(.Until, "expected 'until'");
        try self.parseExp(1);
    }

    fn parseForStat(self: *Parser) ParseError!void {
        try self.expect(.For, "expected 'for'");
        _ = try self.expectName("expected name after 'for'");
        if (try self.match(.Assign)) {
            // numeric for
            try self.parseExp(1);
            try self.expect(.Comma, "expected ',' in numeric for");
            try self.parseExp(1);
            if (try self.match(.Comma)) {
                try self.parseExp(1);
            }
            try self.expect(.Do, "expected 'do' in numeric for");
            try self.parseBlock();
            try self.expect(.End, "expected 'end'");
            return;
        }

        // generic for
        while (try self.match(.Comma)) {
            _ = try self.expectName("expected name in generic for");
        }
        try self.expect(.In, "expected 'in' in generic for");
        try self.parseExplist();
        try self.expect(.Do, "expected 'do' in generic for");
        try self.parseBlock();
        try self.expect(.End, "expected 'end'");
    }

    fn parseFuncStat(self: *Parser) ParseError!void {
        try self.expect(.Function, "expected 'function'");
        try self.parseFuncName();
        try self.parseFuncBody();
    }

    fn parseFuncName(self: *Parser) ParseError!void {
        _ = try self.expectName("expected function name");
        while (try self.match(.Dot)) {
            _ = try self.expectName("expected name after '.'");
        }
        if (try self.match(.Colon)) {
            _ = try self.expectName("expected name after ':'");
        }
    }

    fn parseFuncBody(self: *Parser) ParseError!void {
        try self.expect(.LParen, "expected '('");
        if (!try self.match(.RParen)) {
            try self.parseParList();
            try self.expect(.RParen, "expected ')'");
        }
        try self.parseBlock();
        try self.expect(.End, "expected 'end'");
    }

    fn parseParList(self: *Parser) ParseError!void {
        if (try self.match(.Dots)) return;
        _ = try self.expectName("expected parameter name");
        while (try self.match(.Comma)) {
            if (try self.match(.Dots)) return;
            _ = try self.expectName("expected parameter name");
        }
    }

    fn parseAttribOpt(self: *Parser, allow_close: bool) ParseError!void {
        if (!try self.match(.Lt)) return;
        const t = try self.expectName("expected attribute name");
        const name = t.slice(self.lex.source.bytes);
        const ok = std.mem.eql(u8, name, "const") or (allow_close and std.mem.eql(u8, name, "close"));
        if (!ok) {
            self.setDiag("invalid attribute");
            return error.SyntaxError;
        }
        try self.expect(.Gt, "expected '>'");
    }

    fn parseLocalStat(self: *Parser) ParseError!void {
        try self.expect(.Local, "expected 'local'");
        if (try self.match(.Function)) {
            _ = try self.expectName("expected name after 'local function'");
            try self.parseFuncBody();
            return;
        }

        // local [attrib] namelist [attrib] ['=' explist]
        try self.parseAttribOpt(true);
        _ = try self.expectName("expected local name");
        try self.parseAttribOpt(true);
        while (try self.match(.Comma)) {
            _ = try self.expectName("expected local name");
            try self.parseAttribOpt(true);
        }
        if (try self.match(.Assign)) {
            try self.parseExplist();
        }
    }

    fn parseGlobalStatFunc(self: *Parser) ParseError!void {
        try self.expect(.Global, "expected 'global'");
        if (try self.match(.Function)) {
            _ = try self.expectName("expected name after 'global function'");
            try self.parseFuncBody();
            return;
        }
        try self.parseGlobalStat();
    }

    fn parseGlobalStat(self: *Parser) ParseError!void {
        // global [attrib] '*' | global [attrib] NAME [attrib] {',' NAME [attrib]} ['=' explist]
        try self.parseAttribOpt(false);
        if (try self.match(.Star)) return;
        _ = try self.expectName("expected global name");
        try self.parseAttribOpt(false);
        while (try self.match(.Comma)) {
            _ = try self.expectName("expected global name");
            try self.parseAttribOpt(false);
        }
        if (try self.match(.Assign)) {
            try self.parseExplist();
        }
    }

    fn parseGotoStat(self: *Parser) ParseError!void {
        try self.expect(.Goto, "expected 'goto'");
        _ = try self.expectName("expected label name");
    }

    fn parseLabelStat(self: *Parser) ParseError!void {
        try self.expect(.DbColon, "expected '::'");
        _ = try self.expectName("expected label name");
        try self.expect(.DbColon, "expected '::'");
    }

    fn parseReturnStat(self: *Parser) ParseError!void {
        try self.expect(.Return, "expected 'return'");
        if (isBlockFollow(self.cur.kind) or self.cur.kind == .Semicolon) {
            _ = try self.match(.Semicolon);
            return;
        }
        try self.parseExplist();
        _ = try self.match(.Semicolon);
    }

    const SuffixedType = enum { expr, lvalue, call };

    fn parseExprStat(self: *Parser) ParseError!void {
        const t = try self.parseSuffixedExp();
        if (self.cur.kind == .Assign or self.cur.kind == .Comma) {
            if (t != .lvalue) {
                self.setDiag("assignment to non-variable");
                return error.SyntaxError;
            }
            while (try self.match(.Comma)) {
                try self.parseVar();
            }
            try self.expect(.Assign, "expected '=' in assignment");
            try self.parseExplist();
            return;
        }
        if (t != .call) {
            self.setDiag("statement is not a function call");
            return error.SyntaxError;
        }
    }

    fn parseVar(self: *Parser) ParseError!void {
        const t = try self.parseSuffixedExp();
        if (t != .lvalue) {
            self.setDiag("expected variable");
            return error.SyntaxError;
        }
    }

    fn parseSuffixedExp(self: *Parser) ParseError!SuffixedType {
        var t: SuffixedType = undefined;
        if (self.cur.kind == .Name) {
            try self.advance();
            t = .lvalue;
        } else if (try self.match(.LParen)) {
            try self.parseExp(1);
            try self.expect(.RParen, "expected ')'");
            t = .expr;
        } else {
            self.setDiag("expected expression");
            return error.SyntaxError;
        }

        while (true) {
            switch (self.cur.kind) {
                .Dot => {
                    try self.advance();
                    _ = try self.expectName("expected name after '.'");
                    t = .lvalue;
                },
                .LBracket => {
                    try self.advance();
                    try self.parseExp(1);
                    try self.expect(.RBracket, "expected ']'");
                    t = .lvalue;
                },
                .Colon => {
                    try self.advance();
                    _ = try self.expectName("expected name after ':'");
                    try self.parseArgs();
                    t = .call;
                },
                .LParen, .LBrace, .String => {
                    try self.parseArgs();
                    t = .call;
                },
                else => break,
            }
        }

        return t;
    }

    fn parseArgs(self: *Parser) ParseError!void {
        if (try self.match(.LParen)) {
            if (!try self.match(.RParen)) {
                try self.parseExplist();
                try self.expect(.RParen, "expected ')'");
            }
            return;
        }
        if (self.cur.kind == .String) {
            try self.advance();
            return;
        }
        if (self.cur.kind == .LBrace) {
            try self.parseTableConstructor();
            return;
        }
        self.setDiag("invalid function arguments");
        return error.SyntaxError;
    }

    fn parseTableConstructor(self: *Parser) ParseError!void {
        try self.expect(.LBrace, "expected '{'");
        if (try self.match(.RBrace)) return;
        try self.parseFieldList();
        try self.expect(.RBrace, "expected '}'");
    }

    fn parseFieldList(self: *Parser) ParseError!void {
        try self.parseField();
        while (self.cur.kind == .Comma or self.cur.kind == .Semicolon) {
            try self.advance();
            if (self.cur.kind == .RBrace) break;
            try self.parseField();
        }
    }

    fn parseField(self: *Parser) ParseError!void {
        if (try self.match(.LBracket)) {
            try self.parseExp(1);
            try self.expect(.RBracket, "expected ']'");
            try self.expect(.Assign, "expected '='");
            try self.parseExp(1);
            return;
        }

        if (self.cur.kind == .Name and self.la.kind == .Assign) {
            try self.advance(); // name
            try self.expect(.Assign, "expected '='");
            try self.parseExp(1);
            return;
        }

        try self.parseExp(1);
    }

    fn parseExplist(self: *Parser) ParseError!void {
        try self.parseExp(1);
        while (try self.match(.Comma)) {
            try self.parseExp(1);
        }
    }

    fn parseSimpleExp(self: *Parser) ParseError!void {
        switch (self.cur.kind) {
            .Nil, .True, .False, .Integer, .Number, .String, .Dots => {
                try self.advance();
            },
            .Function => {
                try self.advance();
                try self.parseFuncBody();
            },
            .LBrace => {
                try self.parseTableConstructor();
            },
            else => {
                _ = try self.parseSuffixedExp();
            },
        }
    }

    fn parsePrefix(self: *Parser) ParseError!void {
        switch (self.cur.kind) {
            .Not, .Hash, .Minus, .Tilde => {
                try self.advance();
                try self.parseExp(11);
            },
            else => try self.parseSimpleExp(),
        }
    }

    fn binInfo(k: TokenKind) ?struct { prec: u8, right: bool } {
        return switch (k) {
            .Or => .{ .prec = 1, .right = false },
            .And => .{ .prec = 2, .right = false },

            .Lt, .Gt, .Lte, .Gte, .NotEq, .EqEq => .{ .prec = 3, .right = false },

            .Pipe => .{ .prec = 4, .right = false },
            .Tilde => .{ .prec = 5, .right = false }, // binary xor
            .Amp => .{ .prec = 6, .right = false },

            .Shl, .Shr => .{ .prec = 7, .right = false },

            .Concat => .{ .prec = 8, .right = true },

            .Plus, .Minus => .{ .prec = 9, .right = false },

            .Star, .Slash, .Idiv, .Percent => .{ .prec = 10, .right = false },

            .Caret => .{ .prec = 12, .right = true },

            else => null,
        };
    }

    fn parseExp(self: *Parser, min_prec: u8) ParseError!void {
        try self.parsePrefix();
        while (true) {
            const info = binInfo(self.cur.kind) orelse break;
            if (info.prec < min_prec) break;

            const prec = info.prec;
            const next_min = if (info.right) prec else prec + 1;
            try self.advance(); // op
            try self.parseExp(next_min);
        }
    }
};

test "parser parse-only: basic constructs" {
    const src = @import("source.zig").Source{ .name = "<test>", .bytes = "do local x = 1; if x then x = x + 1 end end" };
    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);
    try p.parseChunk();
}
