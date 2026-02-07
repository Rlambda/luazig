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

test "TokenKind names are stable" {
    try std.testing.expectEqualStrings("global", TokenKind.Global.name());
    try std.testing.expect(TokenKind.Name.hasLexeme());
    try std.testing.expect(!TokenKind.Do.hasLexeme());
}

