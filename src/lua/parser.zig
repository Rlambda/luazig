const std = @import("std");

const Diag = @import("diag.zig").Diag;
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;
const ast = @import("ast.zig");

pub const Parser = struct {
    lex: *Lexer,
    cur: Token,
    la: Token,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    const ParseError = error{SyntaxError};
    const AstError = ParseError || error{OutOfMemory};

    const SuffixedKind = enum { expr, lvalue, call };

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
        while (true) {
            // Lua allows empty statements made only of semicolons.
            while (try self.match(.Semicolon)) {}
            if (isBlockFollow(self.cur.kind)) break;

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
        if (try self.match(.Dots)) {
            // Lua 5.5 allows a named vararg table: '...t'.
            _ = try self.match(.Name);
            return;
        }
        _ = try self.expectName("expected parameter name");
        while (try self.match(.Comma)) {
            if (try self.match(.Dots)) {
                _ = try self.match(.Name);
                return;
            }
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

    // --- AST Builder -------------------------------------------------------

    pub fn parseChunkAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Chunk {
        const block = try self.parseBlockAst(arena);
        const eof_tok = self.cur;
        try self.expect(.Eof, "expected end of file");

        const chunk = try arena.create(ast.Chunk);
        chunk.* = .{
            .span = ast.Span.join(block.span, ast.Span.fromToken(eof_tok)),
            .block = block,
        };
        return chunk;
    }

    fn parseBlockAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Block {
        var stats_list = std.ArrayListUnmanaged(ast.Stat){};

        while (true) {
            while (try self.match(.Semicolon)) {}
            if (isBlockFollow(self.cur.kind)) break;

            const st = try self.parseStatAst(arena);
            try stats_list.append(arena.allocator(), st);
            while (try self.match(.Semicolon)) {}
        }

        const stats = try stats_list.toOwnedSlice(arena.allocator());
        const span = if (stats.len > 0)
            ast.Span.join(stats[0].span, stats[stats.len - 1].span)
        else
            ast.Span.fromToken(self.cur);

        const b = try arena.create(ast.Block);
        b.* = .{ .span = span, .stats = stats };
        return b;
    }

    fn parseStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        return switch (self.cur.kind) {
            .If => try self.parseIfStatAst(arena),
            .While => try self.parseWhileStatAst(arena),
            .Do => try self.parseDoStatAst(arena),
            .For => try self.parseForStatAst(arena),
            .Repeat => try self.parseRepeatStatAst(arena),
            .Function => try self.parseFuncStatAst(arena),
            .Local => try self.parseLocalStatAst(arena),
            .Global => try self.parseGlobalStatFuncAst(arena),
            .DbColon => try self.parseLabelStatAst(arena),
            .Return => try self.parseReturnStatAst(arena),
            .Break => {
                const t = self.cur;
                try self.advance();
                return .{ .span = ast.Span.fromToken(t), .node = .Break };
            },
            .Goto => try self.parseGotoStatAst(arena),
            else => try self.parseExprStatAst(arena),
        };
    }

    fn parseIfStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const if_tok = self.cur;
        try self.expect(.If, "expected 'if'");

        const cond = try self.parseExpAst(arena, 1);
        try self.expect(.Then, "expected 'then'");

        const then_block = try self.parseBlockAst(arena);

        var elseifs_list = std.ArrayListUnmanaged(ast.ElseIf){};
        while (self.cur.kind == .ElseIf) {
            try self.advance();
            const econd = try self.parseExpAst(arena, 1);
            try self.expect(.Then, "expected 'then'");
            const eblock = try self.parseBlockAst(arena);
            try elseifs_list.append(arena.allocator(), .{ .cond = econd, .block = eblock });
        }
        const elseifs = try elseifs_list.toOwnedSlice(arena.allocator());

        var else_block: ?*ast.Block = null;
        if (try self.match(.Else)) {
            else_block = try self.parseBlockAst(arena);
        }

        const end_tok = self.cur;
        try self.expect(.End, "expected 'end'");

        return .{
            .span = ast.Span.join(ast.Span.fromToken(if_tok), ast.Span.fromToken(end_tok)),
            .node = .{ .If = .{
                .cond = cond,
                .then_block = then_block,
                .elseifs = elseifs,
                .else_block = else_block,
            } },
        };
    }

    fn parseWhileStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const while_tok = self.cur;
        try self.expect(.While, "expected 'while'");
        const cond = try self.parseExpAst(arena, 1);
        try self.expect(.Do, "expected 'do'");
        const block = try self.parseBlockAst(arena);
        const end_tok = self.cur;
        try self.expect(.End, "expected 'end'");
        return .{
            .span = ast.Span.join(ast.Span.fromToken(while_tok), ast.Span.fromToken(end_tok)),
            .node = .{ .While = .{ .cond = cond, .block = block } },
        };
    }

    fn parseDoStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const do_tok = self.cur;
        try self.expect(.Do, "expected 'do'");
        const block = try self.parseBlockAst(arena);
        const end_tok = self.cur;
        try self.expect(.End, "expected 'end'");
        return .{
            .span = ast.Span.join(ast.Span.fromToken(do_tok), ast.Span.fromToken(end_tok)),
            .node = .{ .Do = .{ .block = block } },
        };
    }

    fn parseRepeatStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const rep_tok = self.cur;
        try self.expect(.Repeat, "expected 'repeat'");
        const block = try self.parseBlockAst(arena);
        try self.expect(.Until, "expected 'until'");
        const cond = try self.parseExpAst(arena, 1);
        return .{
            .span = ast.Span.join(ast.Span.fromToken(rep_tok), cond.span),
            .node = .{ .Repeat = .{ .block = block, .cond = cond } },
        };
    }

    fn parseForStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const for_tok = self.cur;
        try self.expect(.For, "expected 'for'");

        const name_tok = try self.expectName("expected name after 'for'");
        const name = ast.Name{ .span = ast.Span.fromToken(name_tok) };

        if (try self.match(.Assign)) {
            // numeric for
            const init_exp = try self.parseExpAst(arena, 1);
            try self.expect(.Comma, "expected ',' in numeric for");
            const limit = try self.parseExpAst(arena, 1);
            var step: ?*ast.Exp = null;
            if (try self.match(.Comma)) {
                step = try self.parseExpAst(arena, 1);
            }
            try self.expect(.Do, "expected 'do' in numeric for");
            const block = try self.parseBlockAst(arena);
            const end_tok = self.cur;
            try self.expect(.End, "expected 'end'");

            return .{
                .span = ast.Span.join(ast.Span.fromToken(for_tok), ast.Span.fromToken(end_tok)),
                .node = .{ .ForNumeric = .{
                    .name = name,
                    .init = init_exp,
                    .limit = limit,
                    .step = step,
                    .block = block,
                } },
            };
        }

        // generic for
        var names_list = std.ArrayListUnmanaged(ast.Name){};
        try names_list.append(arena.allocator(), name);
        while (try self.match(.Comma)) {
            const t = try self.expectName("expected name in generic for");
            try names_list.append(arena.allocator(), .{ .span = ast.Span.fromToken(t) });
        }
        const names = try names_list.toOwnedSlice(arena.allocator());

        try self.expect(.In, "expected 'in' in generic for");
        const exps = try self.parseExplistAst(arena);

        try self.expect(.Do, "expected 'do' in generic for");
        const block = try self.parseBlockAst(arena);
        const end_tok = self.cur;
        try self.expect(.End, "expected 'end'");

        return .{
            .span = ast.Span.join(ast.Span.fromToken(for_tok), ast.Span.fromToken(end_tok)),
            .node = .{ .ForGeneric = .{ .names = names, .exps = exps, .block = block } },
        };
    }

    fn parseFuncStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const fun_tok = self.cur;
        try self.expect(.Function, "expected 'function'");
        const name = try self.parseFuncNameAst(arena);
        const body = try self.parseFuncBodyAst(arena);
        return .{
            .span = ast.Span.join(ast.Span.fromToken(fun_tok), body.span),
            .node = .{ .FuncDecl = .{ .name = name, .body = body } },
        };
    }

    fn parseFuncNameAst(self: *Parser, arena: *ast.AstArena) AstError!ast.FuncName {
        const base_tok = try self.expectName("expected function name");
        const base = ast.Name{ .span = ast.Span.fromToken(base_tok) };

        var fields_list = std.ArrayListUnmanaged(ast.Name){};
        while (try self.match(.Dot)) {
            const t = try self.expectName("expected name after '.'");
            try fields_list.append(arena.allocator(), .{ .span = ast.Span.fromToken(t) });
        }
        const fields = try fields_list.toOwnedSlice(arena.allocator());

        var method: ?ast.Name = null;
        if (try self.match(.Colon)) {
            const t = try self.expectName("expected name after ':'");
            method = .{ .span = ast.Span.fromToken(t) };
        }

        const end_span = if (method) |m|
            m.span
        else if (fields.len > 0)
            fields[fields.len - 1].span
        else
            base.span;

        return .{
            .span = ast.Span.join(base.span, end_span),
            .base = base,
            .fields = fields,
            .method = method,
        };
    }

    fn parseFuncBodyAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.FuncBody {
        const lparen_tok = self.cur;
        try self.expect(.LParen, "expected '('");

        var params_list = std.ArrayListUnmanaged(ast.Name){};
        var vararg: ?ast.Vararg = null;

        if (self.cur.kind != .RParen) {
            const pl = try self.parseParListAst(arena);
            params_list = pl.params;
            vararg = pl.vararg;
        }

        const rparen_tok = self.cur;
        try self.expect(.RParen, "expected ')'");

        const body_block = try self.parseBlockAst(arena);
        const end_tok = self.cur;
        try self.expect(.End, "expected 'end'");

        const params = try params_list.toOwnedSlice(arena.allocator());

        const fb = try arena.create(ast.FuncBody);
        fb.* = .{
            .span = ast.Span.join(ast.Span.fromToken(lparen_tok), ast.Span.fromToken(end_tok)),
            .params = params,
            .vararg = vararg,
            .body = body_block,
        };

        _ = rparen_tok;
        return fb;
    }

    fn parseParListAst(self: *Parser, arena: *ast.AstArena) AstError!struct {
        params: std.ArrayListUnmanaged(ast.Name),
        vararg: ?ast.Vararg,
    } {
        var params = std.ArrayListUnmanaged(ast.Name){};
        var vararg: ?ast.Vararg = null;

        if (self.cur.kind == .Dots) {
            const dots_tok = self.cur;
            try self.advance();
            var vname: ?ast.Name = null;
            if (self.cur.kind == .Name) {
                const t = self.cur;
                try self.advance();
                vname = .{ .span = ast.Span.fromToken(t) };
            }
            vararg = .{ .span = ast.Span.fromToken(dots_tok), .name = vname };
            return .{ .params = params, .vararg = vararg };
        }

        const first = try self.expectName("expected parameter name");
        try params.append(arena.allocator(), .{ .span = ast.Span.fromToken(first) });

        while (try self.match(.Comma)) {
            if (self.cur.kind == .Dots) {
                const dots_tok = self.cur;
                try self.advance();
                var vname: ?ast.Name = null;
                if (self.cur.kind == .Name) {
                    const t = self.cur;
                    try self.advance();
                    vname = .{ .span = ast.Span.fromToken(t) };
                }
                vararg = .{ .span = ast.Span.fromToken(dots_tok), .name = vname };
                return .{ .params = params, .vararg = vararg };
            }
            const t = try self.expectName("expected parameter name");
            try params.append(arena.allocator(), .{ .span = ast.Span.fromToken(t) });
        }

        return .{ .params = params, .vararg = vararg };
    }

    fn parseAttribOptAst(self: *Parser, allow_close: bool) AstError!?ast.Attr {
        if (self.cur.kind != .Lt) return null;
        const lt_tok = self.cur;
        try self.advance();

        const t = try self.expectName("expected attribute name");
        const name_bytes = t.slice(self.lex.source.bytes);

        var kind: ast.AttrKind = undefined;
        if (std.mem.eql(u8, name_bytes, "const")) {
            kind = .Const;
        } else if (allow_close and std.mem.eql(u8, name_bytes, "close")) {
            kind = .Close;
        } else {
            self.setDiag("invalid attribute");
            return error.SyntaxError;
        }

        const gt_tok = self.cur;
        try self.expect(.Gt, "expected '>'");

        return .{
            .span = ast.Span.join(ast.Span.fromToken(lt_tok), ast.Span.fromToken(gt_tok)),
            .kind = kind,
        };
    }

    fn parseLocalStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const local_tok = self.cur;
        try self.expect(.Local, "expected 'local'");

        if (self.cur.kind == .Function) {
            try self.advance();
            const name_tok = try self.expectName("expected name after 'local function'");
            const body = try self.parseFuncBodyAst(arena);
            return .{
                .span = ast.Span.join(ast.Span.fromToken(local_tok), body.span),
                .node = .{ .LocalFuncDecl = .{
                    .name = .{ .span = ast.Span.fromToken(name_tok) },
                    .body = body,
                } },
            };
        }

        // local [attrib] namelist [attrib] ['=' explist]
        const prefix_attr = try self.parseAttribOptAst(true);

        var names_list = std.ArrayListUnmanaged(ast.DeclName){};
        const first_name_tok = try self.expectName("expected local name");
        var first_decl: ast.DeclName = .{
            .name = .{ .span = ast.Span.fromToken(first_name_tok) },
            .prefix_attr = prefix_attr,
            .suffix_attr = null,
        };
        first_decl.suffix_attr = try self.parseAttribOptAst(true);
        try names_list.append(arena.allocator(), first_decl);

        while (try self.match(.Comma)) {
            const t = try self.expectName("expected local name");
            var d: ast.DeclName = .{ .name = .{ .span = ast.Span.fromToken(t) } };
            d.suffix_attr = try self.parseAttribOptAst(true);
            try names_list.append(arena.allocator(), d);
        }

        const names = try names_list.toOwnedSlice(arena.allocator());

        var values: ?[]*ast.Exp = null;
        if (try self.match(.Assign)) {
            values = try self.parseExplistAst(arena);
        }

        const end_span = if (values) |vs|
            vs[vs.len - 1].span
        else blk: {
            const last = names[names.len - 1];
            break :blk if (last.suffix_attr) |a| a.span else last.name.span;
        };

        return .{
            .span = ast.Span.join(ast.Span.fromToken(local_tok), end_span),
            .node = .{ .LocalDecl = .{ .names = names, .values = values } },
        };
    }

    fn parseGlobalStatFuncAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const global_tok = self.cur;
        try self.expect(.Global, "expected 'global'");

        if (self.cur.kind == .Function) {
            try self.advance();
            const name_tok = try self.expectName("expected name after 'global function'");
            const body = try self.parseFuncBodyAst(arena);
            return .{
                .span = ast.Span.join(ast.Span.fromToken(global_tok), body.span),
                .node = .{ .GlobalFuncDecl = .{
                    .name = .{ .span = ast.Span.fromToken(name_tok) },
                    .body = body,
                } },
            };
        }

        return try self.parseGlobalStatAst(arena, global_tok);
    }

    fn parseGlobalStatAst(self: *Parser, arena: *ast.AstArena, global_tok: Token) AstError!ast.Stat {
        // global [attrib] '*' | global [attrib] NAME [attrib] {',' NAME [attrib]} ['=' explist]
        const prefix_attr = try self.parseAttribOptAst(false);

        if (self.cur.kind == .Star) {
            const star_tok = self.cur;
            try self.advance();
            const empty = try arena.allocator().alloc(ast.DeclName, 0);
            return .{
                .span = ast.Span.join(ast.Span.fromToken(global_tok), ast.Span.fromToken(star_tok)),
                .node = .{ .GlobalDecl = .{
                    .prefix_attr = prefix_attr,
                    .star = true,
                    .names = empty,
                    .values = null,
                } },
            };
        }

        var names_list = std.ArrayListUnmanaged(ast.DeclName){};
        const first_tok = try self.expectName("expected global name");
        var first_decl: ast.DeclName = .{ .name = .{ .span = ast.Span.fromToken(first_tok) } };
        first_decl.suffix_attr = try self.parseAttribOptAst(false);
        try names_list.append(arena.allocator(), first_decl);

        while (try self.match(.Comma)) {
            const t = try self.expectName("expected global name");
            var d: ast.DeclName = .{ .name = .{ .span = ast.Span.fromToken(t) } };
            d.suffix_attr = try self.parseAttribOptAst(false);
            try names_list.append(arena.allocator(), d);
        }

        const names = try names_list.toOwnedSlice(arena.allocator());

        var values: ?[]*ast.Exp = null;
        if (try self.match(.Assign)) {
            values = try self.parseExplistAst(arena);
        }

        const end_span = if (values) |vs|
            vs[vs.len - 1].span
        else blk: {
            const last = names[names.len - 1];
            break :blk if (last.suffix_attr) |a| a.span else last.name.span;
        };

        return .{
            .span = ast.Span.join(ast.Span.fromToken(global_tok), end_span),
            .node = .{ .GlobalDecl = .{
                .prefix_attr = prefix_attr,
                .star = false,
                .names = names,
                .values = values,
            } },
        };
    }

    fn parseGotoStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        _ = arena;
        const goto_tok = self.cur;
        try self.expect(.Goto, "expected 'goto'");
        const name_tok = try self.expectName("expected label name");
        const label = ast.Name{ .span = ast.Span.fromToken(name_tok) };
        return .{
            .span = ast.Span.join(ast.Span.fromToken(goto_tok), label.span),
            .node = .{ .Goto = .{ .label = label } },
        };
    }

    fn parseLabelStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        _ = arena;
        const start_tok = self.cur;
        try self.expect(.DbColon, "expected '::'");
        const name_tok = try self.expectName("expected label name");
        const label = ast.Name{ .span = ast.Span.fromToken(name_tok) };
        const end_tok = self.cur;
        try self.expect(.DbColon, "expected '::'");
        return .{
            .span = ast.Span.join(ast.Span.fromToken(start_tok), ast.Span.fromToken(end_tok)),
            .node = .{ .Label = .{ .label = label } },
        };
    }

    fn parseReturnStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const ret_tok = self.cur;
        try self.expect(.Return, "expected 'return'");

        if (isBlockFollow(self.cur.kind) or self.cur.kind == .Semicolon) {
            _ = try self.match(.Semicolon);
            const empty = try arena.allocator().alloc(*ast.Exp, 0);
            return .{ .span = ast.Span.fromToken(ret_tok), .node = .{ .Return = .{ .values = empty } } };
        }

        const values = try self.parseExplistAst(arena);
        _ = try self.match(.Semicolon);

        return .{
            .span = ast.Span.join(ast.Span.fromToken(ret_tok), values[values.len - 1].span),
            .node = .{ .Return = .{ .values = values } },
        };
    }

    fn parseExprStatAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Stat {
        const first = try self.parseSuffixedExpAst(arena);

        if (self.cur.kind == .Assign or self.cur.kind == .Comma) {
            if (first.kind != .lvalue) {
                self.setDiag("assignment to non-variable");
                return error.SyntaxError;
            }

            var lhs_list = std.ArrayListUnmanaged(*ast.Exp){};
            try lhs_list.append(arena.allocator(), first.exp);

            while (try self.match(.Comma)) {
                const v = try self.parseVarAst(arena);
                try lhs_list.append(arena.allocator(), v);
            }

            try self.expect(.Assign, "expected '=' in assignment");
            const rhs = try self.parseExplistAst(arena);

            const lhs = try lhs_list.toOwnedSlice(arena.allocator());

            return .{
                .span = ast.Span.join(lhs[0].span, rhs[rhs.len - 1].span),
                .node = .{ .Assign = .{ .lhs = lhs, .rhs = rhs } },
            };
        }

        if (first.kind != .call) {
            self.setDiag("statement is not a function call");
            return error.SyntaxError;
        }

        return .{
            .span = first.exp.span,
            .node = .{ .Call = .{ .call = first.exp } },
        };
    }

    fn parseVarAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Exp {
        const v = try self.parseSuffixedExpAst(arena);
        if (v.kind != .lvalue) {
            self.setDiag("expected variable");
            return error.SyntaxError;
        }
        return v.exp;
    }

    fn parseExplistAst(self: *Parser, arena: *ast.AstArena) AstError![]*ast.Exp {
        var list = std.ArrayListUnmanaged(*ast.Exp){};
        const first = try self.parseExpAst(arena, 1);
        try list.append(arena.allocator(), first);
        while (try self.match(.Comma)) {
            const e = try self.parseExpAst(arena, 1);
            try list.append(arena.allocator(), e);
        }
        return try list.toOwnedSlice(arena.allocator());
    }

    fn parseSimpleExpAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Exp {
        switch (self.cur.kind) {
            .Nil => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .Nil };
                return e;
            },
            .True => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .True };
                return e;
            },
            .False => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .False };
                return e;
            },
            .Integer => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .Integer };
                return e;
            },
            .Number => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .Number };
                return e;
            },
            .String => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .String };
                return e;
            },
            .Dots => {
                const t = self.cur;
                try self.advance();
                const e = try arena.create(ast.Exp);
                e.* = .{ .span = ast.Span.fromToken(t), .node = .Dots };
                return e;
            },
            .Function => {
                const fun_tok = self.cur;
                try self.advance();
                const body = try self.parseFuncBodyAst(arena);
                const e = try arena.create(ast.Exp);
                e.* = .{
                    .span = ast.Span.join(ast.Span.fromToken(fun_tok), body.span),
                    .node = .{ .FuncDef = body },
                };
                return e;
            },
            .LBrace => return try self.parseTableConstructorAst(arena),
            else => {
                const s = try self.parseSuffixedExpAst(arena);
                return s.exp;
            },
        }
    }

    fn parsePrefixAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Exp {
        switch (self.cur.kind) {
            .Not, .Hash, .Minus, .Tilde => {
                const op_tok = self.cur;
                try self.advance();
                const rhs = try self.parseExpAst(arena, 11);
                const e = try arena.create(ast.Exp);
                e.* = .{
                    .span = ast.Span.join(ast.Span.fromToken(op_tok), rhs.span),
                    .node = .{ .UnOp = .{ .op = op_tok.kind, .exp = rhs } },
                };
                return e;
            },
            else => return try self.parseSimpleExpAst(arena),
        }
    }

    fn parseExpAst(self: *Parser, arena: *ast.AstArena, min_prec: u8) AstError!*ast.Exp {
        var lhs = try self.parsePrefixAst(arena);
        while (true) {
            const info = binInfo(self.cur.kind) orelse break;
            if (info.prec < min_prec) break;

            const op_tok = self.cur;
            const prec = info.prec;
            const next_min = if (info.right) prec else prec + 1;
            try self.advance(); // op

            const rhs = try self.parseExpAst(arena, next_min);

            const e = try arena.create(ast.Exp);
            e.* = .{
                .span = ast.Span.join(lhs.span, rhs.span),
                .node = .{ .BinOp = .{ .op = op_tok.kind, .lhs = lhs, .rhs = rhs } },
            };
            lhs = e;
        }
        return lhs;
    }

    fn parseSuffixedExpAst(self: *Parser, arena: *ast.AstArena) AstError!struct { exp: *ast.Exp, kind: SuffixedKind } {
        var kind: SuffixedKind = undefined;
        var base: *ast.Exp = undefined;

        if (self.cur.kind == .Name) {
            const t = self.cur;
            try self.advance();
            const name = ast.Name{ .span = ast.Span.fromToken(t) };
            const e = try arena.create(ast.Exp);
            e.* = .{ .span = name.span, .node = .{ .Name = name } };
            base = e;
            kind = .lvalue;
        } else if (self.cur.kind == .LParen) {
            const lp_tok = self.cur;
            try self.advance();
            const inner = try self.parseExpAst(arena, 1);
            const rp_tok = self.cur;
            try self.expect(.RParen, "expected ')'");
            const e = try arena.create(ast.Exp);
            e.* = .{
                .span = ast.Span.join(ast.Span.fromToken(lp_tok), ast.Span.fromToken(rp_tok)),
                .node = .{ .Paren = inner },
            };
            base = e;
            kind = .expr;
        } else {
            self.setDiag("expected expression");
            return error.SyntaxError;
        }

        while (true) {
            switch (self.cur.kind) {
                .Dot => {
                    try self.advance();
                    const t = try self.expectName("expected name after '.'");
                    const fname = ast.Name{ .span = ast.Span.fromToken(t) };
                    const e = try arena.create(ast.Exp);
                    e.* = .{
                        .span = ast.Span.join(base.span, fname.span),
                        .node = .{ .Field = .{ .object = base, .name = fname } },
                    };
                    base = e;
                    kind = .lvalue;
                },
                .LBracket => {
                    const lb_tok = self.cur;
                    try self.advance();
                    const idx = try self.parseExpAst(arena, 1);
                    const rb_tok = self.cur;
                    try self.expect(.RBracket, "expected ']'");
                    const e = try arena.create(ast.Exp);
                    e.* = .{
                        .span = ast.Span.join(base.span, ast.Span.fromToken(rb_tok)),
                        .node = .{ .Index = .{ .object = base, .index = idx } },
                    };
                    base = e;
                    kind = .lvalue;
                    _ = lb_tok;
                },
                .Colon => {
                    try self.advance();
                    const t = try self.expectName("expected name after ':'");
                    const mname = ast.Name{ .span = ast.Span.fromToken(t) };
                    const a = try self.parseArgsAst(arena);
                    const e = try arena.create(ast.Exp);
                    e.* = .{
                        .span = ast.Span.join(base.span, a.end_span),
                        .node = .{ .MethodCall = .{ .receiver = base, .method = mname, .args = a.args } },
                    };
                    base = e;
                    kind = .call;
                },
                .LParen, .LBrace, .String => {
                    const a = try self.parseArgsAst(arena);
                    const e = try arena.create(ast.Exp);
                    e.* = .{
                        .span = ast.Span.join(base.span, a.end_span),
                        .node = .{ .Call = .{ .func = base, .args = a.args } },
                    };
                    base = e;
                    kind = .call;
                },
                else => break,
            }
        }

        return .{ .exp = base, .kind = kind };
    }

    fn parseArgsAst(self: *Parser, arena: *ast.AstArena) AstError!struct { args: []*ast.Exp, end_span: ast.Span } {
        if (self.cur.kind == .LParen) {
            try self.advance();

            if (self.cur.kind == .RParen) {
                const rp_tok = self.cur;
                try self.advance();
                const empty = try arena.allocator().alloc(*ast.Exp, 0);
                return .{ .args = empty, .end_span = ast.Span.fromToken(rp_tok) };
            }

            const args = try self.parseExplistAst(arena);
            const rp_tok = self.cur;
            try self.expect(.RParen, "expected ')'");
            return .{ .args = args, .end_span = ast.Span.fromToken(rp_tok) };
        }

        if (self.cur.kind == .String) {
            const t = self.cur;
            try self.advance();
            const e = try arena.create(ast.Exp);
            e.* = .{ .span = ast.Span.fromToken(t), .node = .String };
            const args = try arena.allocator().alloc(*ast.Exp, 1);
            args[0] = e;
            return .{ .args = args, .end_span = e.span };
        }

        if (self.cur.kind == .LBrace) {
            const tbl = try self.parseTableConstructorAst(arena);
            const args = try arena.allocator().alloc(*ast.Exp, 1);
            args[0] = tbl;
            return .{ .args = args, .end_span = tbl.span };
        }

        self.setDiag("invalid function arguments");
        return error.SyntaxError;
    }

    fn parseTableConstructorAst(self: *Parser, arena: *ast.AstArena) AstError!*ast.Exp {
        const lb_tok = self.cur;
        try self.expect(.LBrace, "expected '{'");

        var fields: []ast.Field = undefined;
        var end_span: ast.Span = undefined;

        if (self.cur.kind == .RBrace) {
            const rb_tok = self.cur;
            try self.advance();
            fields = try arena.allocator().alloc(ast.Field, 0);
            end_span = ast.Span.fromToken(rb_tok);
        } else {
            fields = try self.parseFieldListAst(arena);
            const rb_tok = self.cur;
            try self.expect(.RBrace, "expected '}'");
            end_span = ast.Span.fromToken(rb_tok);
        }

        const e = try arena.create(ast.Exp);
        e.* = .{
            .span = ast.Span.join(ast.Span.fromToken(lb_tok), end_span),
            .node = .{ .Table = .{ .fields = fields } },
        };
        return e;
    }

    fn parseFieldListAst(self: *Parser, arena: *ast.AstArena) AstError![]ast.Field {
        var list = std.ArrayListUnmanaged(ast.Field){};
        const f0 = try self.parseFieldAst(arena);
        try list.append(arena.allocator(), f0);

        while (self.cur.kind == .Comma or self.cur.kind == .Semicolon) {
            try self.advance();
            if (self.cur.kind == .RBrace) break;
            const f = try self.parseFieldAst(arena);
            try list.append(arena.allocator(), f);
        }

        return try list.toOwnedSlice(arena.allocator());
    }

    fn parseFieldAst(self: *Parser, arena: *ast.AstArena) AstError!ast.Field {
        if (self.cur.kind == .LBracket) {
            const lb_tok = self.cur;
            try self.advance();
            const key = try self.parseExpAst(arena, 1);
            try self.expect(.RBracket, "expected ']'");
            try self.expect(.Assign, "expected '='");
            const value = try self.parseExpAst(arena, 1);
            return .{
                .span = ast.Span.join(ast.Span.fromToken(lb_tok), value.span),
                .node = .{ .Index = .{ .key = key, .value = value } },
            };
        }

        if (self.cur.kind == .Name and self.la.kind == .Assign) {
            const ntok = self.cur;
            try self.advance(); // name
            const name = ast.Name{ .span = ast.Span.fromToken(ntok) };
            try self.expect(.Assign, "expected '='");
            const value = try self.parseExpAst(arena, 1);
            return .{
                .span = ast.Span.join(name.span, value.span),
                .node = .{ .Name = .{ .name = name, .value = value } },
            };
        }

        const v = try self.parseExpAst(arena, 1);
        return .{ .span = v.span, .node = .{ .Array = v } };
    }
};

test "parser parse-only: basic constructs" {
    const src = @import("source.zig").Source{ .name = "<test>", .bytes = "do local x = 1; if x then x = x + 1 end end" };
    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);
    try p.parseChunk();
}

test "parser ast: basic constructs" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;

    const src = Source{ .name = "<test>", .bytes = "do local x = 1; if x then x = x + 1 end end" };
    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();

    const chunk = try p.parseChunkAst(&arena);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try ast.dumpChunk(buf.writer(testing.allocator), src.bytes, chunk);
    try testing.expect(std.mem.startsWith(u8, buf.items, "Chunk\n"));
}
