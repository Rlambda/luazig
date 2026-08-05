const std = @import("std");

pub const TokenKind = enum {
    // Single-character tokens
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Caret,
    Hash,
    Amp,
    Pipe,
    Tilde,
    Assign,
    Lt,
    Gt,
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Semicolon,
    Colon,
    Comma,
    Dot,

    // Reserved words
    And,
    Break,
    Do,
    Else,
    ElseIf,
    End,
    False,
    For,
    Function,
    Global,
    Goto,
    If,
    In,
    Local,
    Nil,
    Not,
    Or,
    Repeat,
    Return,
    Then,
    True,
    Until,
    While,

    // Multi-char tokens
    Idiv, // //
    Concat, // ..
    Dots, // ...
    EqEq, // ==
    Gte, // >=
    Lte, // <=
    NotEq, // ~=
    Shl, // <<
    Shr, // >>
    DbColon, // ::

    // Literals and misc
    Number,
    Integer,
    Name,
    String,
    Eof,

    pub fn name(self: TokenKind) []const u8 {
        return switch (self) {
            // Single-char
            .Plus => "+",
            .Minus => "-",
            .Star => "*",
            .Slash => "/",
            .Percent => "%",
            .Caret => "^",
            .Hash => "#",
            .Amp => "&",
            .Pipe => "|",
            .Tilde => "~",
            .Assign => "=",
            .Lt => "<",
            .Gt => ">",
            .LParen => "(",
            .RParen => ")",
            .LBrace => "{",
            .RBrace => "}",
            .LBracket => "[",
            .RBracket => "]",
            .Semicolon => ";",
            .Colon => ":",
            .Comma => ",",
            .Dot => ".",

            // Keywords
            .And => "and",
            .Break => "break",
            .Do => "do",
            .Else => "else",
            .ElseIf => "elseif",
            .End => "end",
            .False => "false",
            .For => "for",
            .Function => "function",
            .Global => "global",
            .Goto => "goto",
            .If => "if",
            .In => "in",
            .Local => "local",
            .Nil => "nil",
            .Not => "not",
            .Or => "or",
            .Repeat => "repeat",
            .Return => "return",
            .Then => "then",
            .True => "true",
            .Until => "until",
            .While => "while",

            // Multi-char
            .Idiv => "//",
            .Concat => "..",
            .Dots => "...",
            .EqEq => "==",
            .Gte => ">=",
            .Lte => "<=",
            .NotEq => "~=",
            .Shl => "<<",
            .Shr => ">>",
            .DbColon => "::",

            // Literals
            .Number => "<number>",
            .Integer => "<integer>",
            .Name => "<name>",
            .String => "<string>",
            .Eof => "<eof>",
        };
    }

    pub fn hasLexeme(self: TokenKind) bool {
        return switch (self) {
            .Name, .String, .Number, .Integer => true,
            else => false,
        };
    }
};

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
    line: u32,
    col: u32,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// PUC `luaX_token2str` (llex.c:87-101): format a token kind as a
/// human-readable string for error messages.
///
/// - Single printable char → `'<char>'`
/// - Control char → `'<\N>'`
/// - Keyword/multi-char symbol → `'<name>'`
/// - `TK_NAME`/`TK_STRING`/`TK_FLT`/`TK_INT` → bare `<name>`/`<string>`/`<number>`/`<integer>`
///   (PUC returns these without quotes; `txtToken` adds quotes for the lexeme)
/// - `TK_EOS` → `<eof>`
///
/// Returns a static string (no allocation needed).
pub fn tokenKindToNearText(kind: TokenKind) []const u8 {
    return switch (kind) {
        // Literals with fixed format (PUC returns these bare, no quotes)
        .Name => "<name>",
        .String => "<string>",
        .Number => "<number>",
        .Integer => "<integer>",
        .Eof => "<eof>",
        // Keywords and symbols: wrap in single quotes (PUC `luaX_token2str`)
        else => blk: {
            const n = kind.name();
            // Single-char symbols and multi-char operators/keywords all get
            // quoted. We return the name() here; the caller wraps it.
            break :blk n;
        },
    };
}

/// PUC `txtToken` (llex.c:104-113): format a token for the `near <token>`
/// suffix in error messages. For `TK_NAME`/`TK_STRING`/`TK_FLT`/`TK_INT`,
/// the actual lexeme is wrapped in single quotes. For other tokens, the
/// kind's canonical text is used (quoted for symbols/keywords, bare for
/// `<eof>`/`<number>`/etc.).
///
/// Writes into `buf` and returns a slice. The caller must ensure `buf` is
/// large enough (e.g. 128 bytes).
pub fn tokenToNearText(buf: []u8, tok: Token, source: []const u8) []const u8 {
    switch (tok.kind) {
        .Name, .String, .Number, .Integer => {
            // PUC wraps the lexeme in single quotes: `'foo'`, `'3.14'`, etc.
            const lexeme = tok.slice(source);
            return std.fmt.bufPrint(buf, "'{s}'", .{lexeme}) catch "'<token>'";
        },
        else => {
            const n = tok.kind.name();
            // PUC returns `<eof>`, `<number>`, etc. bare (no quotes) for
            // the fixed-format tokens, and quotes keywords/symbols.
            if (n.len > 0 and n[0] == '<' and n[n.len - 1] == '>') {
                return n;
            }
            return std.fmt.bufPrint(buf, "'{s}'", .{n}) catch "'<token>'";
        },
    }
}

test "TokenKind names are stable" {
    try std.testing.expectEqualStrings("global", TokenKind.Global.name());
    try std.testing.expect(TokenKind.Name.hasLexeme());
    try std.testing.expect(!TokenKind.Do.hasLexeme());
}

test "tokenToNearText for EOF" {
    var buf: [128]u8 = undefined;
    const tok = Token{ .kind = .Eof, .start = 0, .end = 0, .line = 1, .col = 1 };
    try std.testing.expectEqualStrings("<eof>", tokenToNearText(buf[0..], tok, ""));
}

test "tokenToNearText for Name wraps lexeme" {
    var buf: [128]u8 = undefined;
    const source = "foo bar";
    const tok = Token{ .kind = .Name, .start = 0, .end = 3, .line = 1, .col = 1 };
    try std.testing.expectEqualStrings("'foo'", tokenToNearText(buf[0..], tok, source));
}

test "tokenToNearText for keyword quotes name" {
    var buf: [128]u8 = undefined;
    const tok = Token{ .kind = .End, .start = 0, .end = 3, .line = 1, .col = 1 };
    try std.testing.expectEqualStrings("'end'", tokenToNearText(buf[0..], tok, ""));
}

test "tokenToNearText for symbol quotes char" {
    var buf: [128]u8 = undefined;
    const tok = Token{ .kind = .Semicolon, .start = 0, .end = 1, .line = 1, .col = 1 };
    try std.testing.expectEqualStrings("';'", tokenToNearText(buf[0..], tok, ""));
}
