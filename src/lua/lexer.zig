const std = @import("std");

const Diag = @import("diag.zig").Diag;
const Source = @import("source.zig").Source;
const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;

pub const Lexer = struct {
    source: Source,
    i: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    pub fn init(source: Source) Lexer {
        var self: Lexer = .{ .source = source };
        self.skipBomAndShebang();
        return self;
    }

    pub fn diagString(self: *Lexer) []const u8 {
        const d = self.diag orelse return "unknown error";
        return d.bufFormat(self.diag_buf[0..]);
    }

    fn setDiag(self: *Lexer, msg: []const u8) void {
        self.diag = .{
            .source_name = self.source.name,
            .line = self.line,
            .col = self.col,
            .msg = msg,
        };
    }

    fn bytes(self: *Lexer) []const u8 {
        return self.source.bytes;
    }

    fn atEof(self: *Lexer) bool {
        return self.i >= self.bytes().len;
    }

    fn peek(self: *Lexer) u8 {
        if (self.atEof()) return 0;
        return self.bytes()[self.i];
    }

    fn peekN(self: *Lexer, n: usize) u8 {
        const idx = self.i + n;
        if (idx >= self.bytes().len) return 0;
        return self.bytes()[idx];
    }

    fn advanceByte(self: *Lexer) u8 {
        const c = self.peek();
        if (self.atEof()) return 0;
        self.i += 1;
        self.col += 1;
        return c;
    }

    fn consumeNewline(self: *Lexer) void {
        if (self.atEof()) return;
        const old = self.peek();
        _ = self.advanceByte(); // consume old newline char (col will be reset below)
        const nxt = self.peek();
        if ((old == '\n' and nxt == '\r') or (old == '\r' and nxt == '\n')) {
            _ = self.advanceByte();
        }
        self.line += 1;
        self.col = 1;
    }

    fn skipBomAndShebang(self: *Lexer) void {
        // Skip UTF-8 BOM.
        if (self.bytes().len >= 3 and self.bytes()[0] == 0xEF and self.bytes()[1] == 0xBB and self.bytes()[2] == 0xBF) {
            self.i = 3;
        }
        // Skip shebang line ("#!..."), which Lua allows in the first line.
        if (!self.atEof() and self.peek() == '#' and self.peekN(1) == '!') {
            while (!self.atEof() and self.peek() != '\n' and self.peek() != '\r') _ = self.advanceByte();
            if (self.peek() == '\n' or self.peek() == '\r') self.consumeNewline();
        }
    }

    fn isSpace(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\x0B', '\x0C' => true, // \v, \f
            else => false,
        };
    }

    fn isNewline(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn skipSep(self: *Lexer, bracket: u8) usize {
        // Implements Lua's skip_sep: reads a sequence '[=*[' or ']=*]'.
        // Leaves the second bracket as the current char.
        _ = self.advanceByte(); // consume first bracket
        var count: usize = 0;
        while (self.peek() == '=') : (count += 1) _ = self.advanceByte();
        if (self.peek() == bracket) return count + 2;
        if (count == 0) return 1;
        return 0;
    }

    fn readLongString(self: *Lexer, sep: usize, is_comment: bool) !Token {
        // Current char must be the second '[' of the opening delimiter.
        const delim_start_idx = self.i - (sep - 1);
        const delim_start_line = self.line;
        const delim_start_col = self.col - @as(u32, @intCast(sep - 1));
        _ = self.advanceByte(); // skip 2nd '['
        // Long strings may start with a newline.
        if (isNewline(self.peek())) self.consumeNewline();

        while (true) {
            if (self.atEof()) {
                self.setDiag("unfinished long string/comment");
                return error.SyntaxError;
            }
            const c = self.peek();
            if (c == ']') {
                const save_i = self.i;
                const save_line = self.line;
                const save_col = self.col;
                const got = self.skipSep(']');
                if (got == sep) {
                    _ = self.advanceByte(); // skip 2nd ']'
                    const end_idx = self.i;
                    if (is_comment) {
                        return .{ .kind = .String, .start = delim_start_idx, .end = end_idx, .line = delim_start_line, .col = delim_start_col };
                    }
                    return .{ .kind = .String, .start = delim_start_idx, .end = end_idx, .line = delim_start_line, .col = delim_start_col };
                }
                // Not a closing delimiter; restore and continue.
                self.i = save_i;
                self.line = save_line;
                self.col = save_col;
                _ = self.advanceByte();
                continue;
            }
            if (c == '\n' or c == '\r') {
                self.consumeNewline();
                continue;
            }
            _ = self.advanceByte();
        }
    }

    fn readShortString(self: *Lexer, delim: u8, start_line: u32, start_col: u32, start_idx: usize) !Token {
        // Consume opening quote.
        _ = self.advanceByte();
        while (true) {
            if (self.atEof()) {
                self.setDiag("unfinished string");
                return error.SyntaxError;
            }
            const c = self.peek();
            if (c == delim) {
                _ = self.advanceByte();
                return .{ .kind = .String, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            }
            if (isNewline(c)) {
                self.setDiag("unfinished string");
                return error.SyntaxError;
            }
            if (c == '\\') {
                _ = self.advanceByte();
                if (self.atEof()) {
                    self.setDiag("unfinished string escape");
                    return error.SyntaxError;
                }
                const e = self.peek();
                if (e == 'z') {
                    _ = self.advanceByte();
                    while (isSpace(self.peek()) or isNewline(self.peek())) {
                        if (isNewline(self.peek())) self.consumeNewline() else _ = self.advanceByte();
                    }
                    continue;
                }
                if (isNewline(e)) {
                    // A backslash-newline escape consumes a logical newline.
                    self.consumeNewline();
                    continue;
                }
                switch (e) {
                    'a', 'b', 'f', 'n', 'r', 't', 'v', '\\', '"', '\'' => {
                        _ = self.advanceByte();
                    },
                    'x' => {
                        _ = self.advanceByte();
                        if (!isHexDigit(self.peek()) or !isHexDigit(self.peekN(1))) {
                            self.setDiag("invalid hex escape");
                            return error.SyntaxError;
                        }
                        _ = self.advanceByte();
                        _ = self.advanceByte();
                    },
                    'u' => {
                        _ = self.advanceByte();
                        if (self.peek() != '{') {
                            self.setDiag("invalid unicode escape");
                            return error.SyntaxError;
                        }
                        _ = self.advanceByte();
                        var digits: usize = 0;
                        while (!self.atEof() and self.peek() != '}') {
                            if (!isHexDigit(self.peek()) or digits >= 8) {
                                self.setDiag("invalid unicode escape");
                                return error.SyntaxError;
                            }
                            _ = self.advanceByte();
                            digits += 1;
                        }
                        if (self.atEof() or self.peek() != '}' or digits == 0) {
                            self.setDiag("invalid unicode escape");
                            return error.SyntaxError;
                        }
                        _ = self.advanceByte();
                    },
                    else => {
                        if (isDigit(e)) {
                            var val: u32 = 0;
                            var count: usize = 0;
                            while (count < 3 and isDigit(self.peek())) : (count += 1) {
                                val = (val * 10) + @as(u32, self.peek() - '0');
                                _ = self.advanceByte();
                            }
                            if (val > 255) {
                                self.setDiag("decimal escape too large");
                                return error.SyntaxError;
                            }
                        } else {
                            self.setDiag("invalid escape sequence");
                            return error.SyntaxError;
                        }
                    },
                }
                continue;
            }
            _ = self.advanceByte();
        }
    }

    fn readNameOrKeyword(self: *Lexer, start_line: u32, start_col: u32, start_idx: usize) Token {
        _ = self.advanceByte();
        while (isAlpha(self.peek()) or isDigit(self.peek())) _ = self.advanceByte();
        const s = self.bytes()[start_idx..self.i];

        const map = std.StaticStringMap(TokenKind).initComptime(.{
            .{ "and", .And },
            .{ "break", .Break },
            .{ "do", .Do },
            .{ "else", .Else },
            .{ "elseif", .ElseIf },
            .{ "end", .End },
            .{ "false", .False },
            .{ "for", .For },
            .{ "function", .Function },
            .{ "global", .Global },
            .{ "goto", .Goto },
            .{ "if", .If },
            .{ "in", .In },
            .{ "local", .Local },
            .{ "nil", .Nil },
            .{ "not", .Not },
            .{ "or", .Or },
            .{ "repeat", .Repeat },
            .{ "return", .Return },
            .{ "then", .Then },
            .{ "true", .True },
            .{ "until", .Until },
            .{ "while", .While },
        });

        const kind = map.get(s) orelse .Name;
        return .{ .kind = kind, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
    }

    fn readNumeral(self: *Lexer, start_line: u32, start_col: u32, start_idx: usize) !Token {
        // Roughly matches Lua's permissive lexer and then validates the
        // resulting lexeme using Zig's number parsers, similar to Lua's
        // `luaO_str2num` validation step.
        var has_dot = false;
        var has_exp = false;
        var is_hex = false;

        if (self.peek() == '.') {
            has_dot = true;
            _ = self.advanceByte();
        }

        if (self.peek() == '0' and (self.peekN(1) == 'x' or self.peekN(1) == 'X')) {
            is_hex = true;
            _ = self.advanceByte();
            _ = self.advanceByte();
        }

        while (true) {
            const c = self.peek();
            if (is_hex) {
                if (isHexDigit(c)) {
                    _ = self.advanceByte();
                    continue;
                }
                if (c == '.') {
                    has_dot = true;
                    _ = self.advanceByte();
                    continue;
                }
                if (c == 'p' or c == 'P') {
                    has_exp = true;
                    _ = self.advanceByte();
                    if (self.peek() == '+' or self.peek() == '-') _ = self.advanceByte();
                    continue;
                }
            } else {
                if (isDigit(c)) {
                    _ = self.advanceByte();
                    continue;
                }
                if (c == '.') {
                    has_dot = true;
                    _ = self.advanceByte();
                    continue;
                }
                if (c == 'e' or c == 'E') {
                    has_exp = true;
                    _ = self.advanceByte();
                    if (self.peek() == '+' or self.peek() == '-') _ = self.advanceByte();
                    continue;
                }
            }
            break;
        }

        // Numeral cannot touch an identifier character.
        if (isAlpha(self.peek())) {
            self.setDiag("malformed number");
            return error.SyntaxError;
        }

        const s = self.bytes()[start_idx..self.i];

        const want_float = has_dot or has_exp;
        var kind: TokenKind = undefined;

        if (want_float) {
            _ = std.fmt.parseFloat(f64, s) catch {
                self.setDiag("malformed number");
                return error.SyntaxError;
            };
            kind = .Number;
        } else {
            // Integers that overflow Lua's integer range can still be accepted
            // as floats by the reference parser.
            _ = std.fmt.parseInt(i64, s, 0) catch {
                _ = std.fmt.parseFloat(f64, s) catch {
                    self.setDiag("malformed number");
                    return error.SyntaxError;
                };
                kind = .Number;
                return .{ .kind = kind, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            };
            kind = .Integer;
        }

        return .{ .kind = kind, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
    }

    fn skipWhitespaceAndComments(self: *Lexer) !void {
        while (true) {
            if (self.atEof()) return;
            const c = self.peek();
            if (isNewline(c)) {
                self.consumeNewline();
                continue;
            }
            if (isSpace(c)) {
                _ = self.advanceByte();
                continue;
            }

            // Comments: '--'...
            if (c == '-' and self.peekN(1) == '-') {
                _ = self.advanceByte();
                _ = self.advanceByte();
                if (self.peek() == '[') {
                    const sep = self.skipSep('[');
                    if (sep >= 2) {
                        _ = try self.readLongString(sep, true);
                        continue;
                    }
                }
                while (!self.atEof() and !isNewline(self.peek())) _ = self.advanceByte();
                continue;
            }

            return;
        }
    }

    pub fn next(self: *Lexer) !Token {
        try self.skipWhitespaceAndComments();
        self.diag = null;

        const c = self.peek();
        const start_line = self.line;
        const start_col = self.col;
        const start_idx = self.i;

        if (self.atEof()) {
            return .{ .kind = .Eof, .start = self.i, .end = self.i, .line = start_line, .col = start_col };
        }

        // Identifiers/keywords
        if (isAlpha(c)) {
            return self.readNameOrKeyword(start_line, start_col, start_idx);
        }

        // Numerals
        if (isDigit(c) or (c == '.' and isDigit(self.peekN(1)))) {
            return try self.readNumeral(start_line, start_col, start_idx);
        }

        switch (c) {
            '[' => {
                const sep = self.skipSep('[');
                if (sep >= 2) return try self.readLongString(sep, false);
                if (sep == 0) {
                    self.setDiag("invalid long string delimiter");
                    return error.SyntaxError;
                }
                return .{ .kind = .LBracket, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '=' => {
                _ = self.advanceByte();
                if (self.peek() == '=') {
                    _ = self.advanceByte();
                    return .{ .kind = .EqEq, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Assign, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '<' => {
                _ = self.advanceByte();
                if (self.peek() == '=') {
                    _ = self.advanceByte();
                    return .{ .kind = .Lte, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                if (self.peek() == '<') {
                    _ = self.advanceByte();
                    return .{ .kind = .Shl, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Lt, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '>' => {
                _ = self.advanceByte();
                if (self.peek() == '=') {
                    _ = self.advanceByte();
                    return .{ .kind = .Gte, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                if (self.peek() == '>') {
                    _ = self.advanceByte();
                    return .{ .kind = .Shr, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Gt, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '/' => {
                _ = self.advanceByte();
                if (self.peek() == '/') {
                    _ = self.advanceByte();
                    return .{ .kind = .Idiv, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Slash, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '~' => {
                _ = self.advanceByte();
                if (self.peek() == '=') {
                    _ = self.advanceByte();
                    return .{ .kind = .NotEq, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Tilde, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            ':' => {
                _ = self.advanceByte();
                if (self.peek() == ':') {
                    _ = self.advanceByte();
                    return .{ .kind = .DbColon, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Colon, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '"' => return try self.readShortString('"', start_line, start_col, start_idx),
            '\'' => return try self.readShortString('\'', start_line, start_col, start_idx),
            '.' => {
                _ = self.advanceByte();
                if (self.peek() == '.') {
                    _ = self.advanceByte();
                    if (self.peek() == '.') {
                        _ = self.advanceByte();
                        return .{ .kind = .Dots, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                    }
                    return .{ .kind = .Concat, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
                }
                return .{ .kind = .Dot, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '+' => {
                _ = self.advanceByte();
                return .{ .kind = .Plus, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '-' => {
                _ = self.advanceByte();
                return .{ .kind = .Minus, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '*' => {
                _ = self.advanceByte();
                return .{ .kind = .Star, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '%' => {
                _ = self.advanceByte();
                return .{ .kind = .Percent, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '^' => {
                _ = self.advanceByte();
                return .{ .kind = .Caret, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '#' => {
                _ = self.advanceByte();
                return .{ .kind = .Hash, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '&' => {
                _ = self.advanceByte();
                return .{ .kind = .Amp, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '|' => {
                _ = self.advanceByte();
                return .{ .kind = .Pipe, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '(' => {
                _ = self.advanceByte();
                return .{ .kind = .LParen, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            ')' => {
                _ = self.advanceByte();
                return .{ .kind = .RParen, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '{' => {
                _ = self.advanceByte();
                return .{ .kind = .LBrace, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            '}' => {
                _ = self.advanceByte();
                return .{ .kind = .RBrace, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            ']' => {
                _ = self.advanceByte();
                return .{ .kind = .RBracket, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            ';' => {
                _ = self.advanceByte();
                return .{ .kind = .Semicolon, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            ',' => {
                _ = self.advanceByte();
                return .{ .kind = .Comma, .start = start_idx, .end = self.i, .line = start_line, .col = start_col };
            },
            else => {
                self.setDiag("unexpected symbol");
                return error.SyntaxError;
            },
        }
    }
};

test "lexer tokenizes global declaration" {
    const src = Source{ .name = "<test>", .bytes = "global <const> *\n" };
    var lex = Lexer.init(src);
    const t1 = try lex.next();
    try std.testing.expectEqual(TokenKind.Global, t1.kind);
    _ = try lex.next(); // <
    _ = try lex.next(); // const
    _ = try lex.next(); // >
    const star = try lex.next();
    try std.testing.expectEqual(TokenKind.Star, star.kind);
}

test "lexer rejects malformed number 1..2" {
    const src = Source{ .name = "<test>", .bytes = "print(1..2)\n" };
    var lex = Lexer.init(src);
    _ = try lex.next(); // print
    _ = try lex.next(); // (
    try std.testing.expectError(error.SyntaxError, lex.next());
}

test "lexer tokenizes concat with spaces: 1 .. 2" {
    const src = Source{ .name = "<test>", .bytes = "print(1 .. 2)\n" };
    var lex = Lexer.init(src);
    _ = try lex.next(); // print
    _ = try lex.next(); // (
    const one = try lex.next();
    try std.testing.expectEqual(TokenKind.Integer, one.kind);
    const cc = try lex.next();
    try std.testing.expectEqual(TokenKind.Concat, cc.kind);
    const two = try lex.next();
    try std.testing.expectEqual(TokenKind.Integer, two.kind);
}

test "lexer accepts hex float without p exponent (Lua-compatible): 0x1.2" {
    const src = Source{ .name = "<test>", .bytes = "return 0x1.2\n" };
    var lex = Lexer.init(src);
    _ = try lex.next(); // return
    const num = try lex.next();
    try std.testing.expectEqual(TokenKind.Number, num.kind);
}

test "lexer counts CR as newline inside long string" {
    const src = Source{ .name = "<test>", .bytes = "return [[\nA\r]], x\n" };
    var lex = Lexer.init(src);
    _ = try lex.next(); // return
    _ = try lex.next(); // long string
    const comma = try lex.next();
    try std.testing.expectEqual(TokenKind.Comma, comma.kind);
    try std.testing.expectEqual(@as(u32, 3), comma.line);
}
