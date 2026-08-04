//! Recursive-descent parser for the Nix expression language, faithful
//! to Nix 2.34's `parser.y` grammar and precedence table.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    ExpectedToken,
    UnterminatedString,
    DynamicAttrsInLet,
    InvalidInteger,
    InvalidFloat,
    DuplicateFormal,
    EmptyBindings,
};

pub const Parser = struct {
    alloc: std.mem.Allocator,
    toks: []const Token,
    i: usize = 0,
    base_dir: []const u8,
    home_dir: []const u8,
    file: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, toks: []const Token, base_dir: []const u8, home_dir: []const u8) Parser {
        return .{ .alloc = alloc, .toks = toks, .base_dir = base_dir, .home_dir = home_dir };
    }

    fn peek(self: *Parser) Token {
        if (self.i >= self.toks.len) return .{ .kind = .eof, .text = "", .line = 0, .col = 0 };
        return self.toks[self.i];
    }

    fn peekAt(self: *Parser, off: usize) Token {
        const j = self.i + off;
        if (j >= self.toks.len) return .{ .kind = .eof, .text = "", .line = 0, .col = 0 };
        return self.toks[j];
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (self.i < self.toks.len) self.i += 1;
        return t;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        const t = self.peek();
        if (t.kind != kind) return error.ExpectedToken;
        return self.advance();
    }

    fn isIdent(self: *Parser, text: []const u8) bool {
        const t = self.peek();
        return t.kind == .ident and std.mem.eql(u8, t.text, text);
    }

    fn expectIdent(self: *Parser, text: []const u8) ParseError!void {
        if (!self.isIdent(text)) return error.ExpectedToken;
        _ = self.advance();
    }

    pub fn parse(self: *Parser) ParseError!*ast.Expr {
        const e = try self.parseExpr();
        const t = self.peek();
        if (t.kind != .eof) return error.UnexpectedToken;
        return e;
    }

    fn allocExpr(self: *Parser, e: ast.Kind) ParseError!*ast.Expr {
        const p = try self.alloc.create(ast.Expr);
        const t = self.peek();
        p.* = .{ .pos = .{ .file = self.file, .line = @intCast(t.line), .col = @intCast(t.col) }, .kind = e };
        return p;
    }

    fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        // Lambdas:  ID ':' expr  |  ID '@' formals ':'  |  formals ':'  |  formals '@' ID ':'
        if (t.kind == .ident and !lexer.isKeyword(t.text) and !std.mem.eql(u8, t.text, "or")) {
            const next = self.peekAt(1);
            if (next.kind == .colon) {
                const lam_pos = t;
                _ = self.advance(); // ID
                _ = try self.expect(.colon);
                const body = try self.parseExpr();
                return self.allocExpr(.{ .lambda = .{ .arg = t.text, .formals = null, .arg_name = null, .body = body, .pos = .{ .file = self.file, .line = @intCast(lam_pos.line), .col = @intCast(lam_pos.col) } } });
            }
            if (next.kind == .at) {
                // ID '@' formals ':' expr
                const arg_name = t.text;
                _ = self.advance(); // ID
                _ = self.advance(); // @
                const formals = try self.parseFormals();
                _ = try self.expect(.colon);
                const body = try self.parseExpr();
                return self.allocExpr(.{ .lambda = .{ .arg = null, .formals = formals, .arg_name = arg_name, .body = body, .pos = .{ .file = self.file, .line = @intCast(t.line), .col = @intCast(t.col) } } });
            }
        }
        if (t.kind == .lbrace and self.isBraceFormals()) {
            const lam_pos = t;
            const formals = try self.parseFormals();
            var arg_name: ?[]const u8 = null;
            if (self.peek().kind == .at) {
                _ = self.advance();
                const id = self.peek();
                if (id.kind != .ident) return error.ExpectedToken;
                _ = self.advance();
                arg_name = id.text;
            }
            _ = try self.expect(.colon);
            const body = try self.parseExpr();
            return self.allocExpr(.{ .lambda = .{ .arg = null, .formals = formals, .arg_name = arg_name, .body = body, .pos = .{ .file = self.file, .line = @intCast(lam_pos.line), .col = @intCast(lam_pos.col) } } });
        }

        if (self.isIdent("assert")) {
            _ = self.advance();
            const cond = try self.parseExpr();
            _ = try self.expect(.semicolon);
            const body = try self.parseExpr();
            return self.allocExpr(.{ .assert_ = .{ .cond = cond, .body = body } });
        }
        if (self.isIdent("with")) {
            _ = self.advance();
            const attrs = try self.parseExpr();
            _ = try self.expect(.semicolon);
            const body = try self.parseExpr();
            return self.allocExpr(.{ .with_ = .{ .attrs = attrs, .body = body } });
        }
        if (self.isIdent("let")) {
            // Legacy:  let binds in expr
            _ = self.advance();
            const binds = try self.parseBindsMode(false, true);
            try self.expectIdent("in");
            const body = try self.parseExpr();
            return self.allocExpr(.{ .let_rec = .{ .binds = binds, .body = body } });
        }
        if (self.isIdent("if")) {
            _ = self.advance();
            const cond = try self.parseExpr();
            try self.expectIdent("then");
            const then = try self.parseExpr();
            try self.expectIdent("else");
            const els = try self.parseExpr();
            return self.allocExpr(.{ .if_ = .{ .cond = cond, .then = then, .else_ = els } });
        }
        return self.parsePipeExpr();
    }

    fn parsePipeExpr(self: *Parser) ParseError!*ast.Expr {
        var e = try self.parseOpExpr();
        while (true) {
            const t = self.peek();
            if (t.kind == .pipe_from) {
                // f <| x  ==  f x
                _ = self.advance();
                const rhs = try self.parsePipeExpr();
                e = try self.allocExpr(.{ .apply = .{ .fun = e, .arg = rhs } });
            } else if (t.kind == .pipe_into) {
                // x |> f  ==  f x
                _ = self.advance();
                const rhs = try self.parsePipeExpr();
                e = try self.allocExpr(.{ .apply = .{ .fun = rhs, .arg = e } });
            } else break;
        }
        return e;
    }

    // Precedences (low → high), from parser.y:
    // -> 1 | || 2 | && 3 | == != 4 | < > <= >= 5 | // 6 | ! 7 | + - 8 | * / 9 | ++ 10 | ? 11 | (unary -) 12
    const prec_impl: u8 = 1;
    const prec_or: u8 = 2;
    const prec_and: u8 = 3;
    const prec_eq: u8 = 4;
    const prec_comp: u8 = 5;
    const prec_update: u8 = 6;
    const prec_not: u8 = 7;
    const prec_add: u8 = 8;
    const prec_mul: u8 = 9;
    const prec_concat: u8 = 10;
    const prec_hasattr: u8 = 11;
    const prec_negate: u8 = 12;

    fn parseOpExpr(self: *Parser) ParseError!*ast.Expr {
        return self.parseExpression(1);
    }

    fn parsePrefixOrApp(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        if (t.kind == .not_) {
            _ = self.advance();
            const e = try self.parseExpression(prec_not);
            return self.allocExpr(.{ .not_ = e });
        }
        if (t.kind == .minus) {
            _ = self.advance();
            const e = try self.parseExpression(prec_negate);
            const zero = try self.allocExpr(.{ .int = 0 });
            const args = try self.alloc.alloc(*ast.Expr, 2);
            args[0] = zero;
            args[1] = e;
            return self.allocExpr(.{ .call_builtin = .{ .name = "sub", .args = args } });
        }
        return self.parseApp();
    }

    const InfixInfo = struct { prec: u8, right_assoc: bool, nonassoc: bool };

    fn infixInfo(kind: TokenKind) ?InfixInfo {
        return switch (kind) {
            .impl => .{ .prec = 1, .right_assoc = true, .nonassoc = false },
            .or_ => .{ .prec = 2, .right_assoc = false, .nonassoc = false },
            .and_ => .{ .prec = 3, .right_assoc = false, .nonassoc = false },
            .eq, .neq => .{ .prec = 4, .right_assoc = false, .nonassoc = true },
            .lt, .gt, .leq, .geq => .{ .prec = 5, .right_assoc = false, .nonassoc = true },
            .update => .{ .prec = 6, .right_assoc = true, .nonassoc = false },
            .plus, .minus => .{ .prec = 8, .right_assoc = false, .nonassoc = false },
            .star, .slash => .{ .prec = 9, .right_assoc = false, .nonassoc = false },
            .concat => .{ .prec = 10, .right_assoc = true, .nonassoc = false },
            else => null,
        };
    }

    fn parseExpression(self: *Parser, min_prec: u8) ParseError!*ast.Expr {
        var left = try self.parsePrefixOrApp();
        var last_nonassoc: ?u8 = null;
        while (true) {
            const t = self.peek();
            if (t.kind == .question) {
                if (prec_hasattr < min_prec) break;
                if (last_nonassoc) |p| if (p == prec_hasattr) return error.UnexpectedToken;
                _ = self.advance();
                const attrpath = try self.parseAttrPath();
                left = try self.allocExpr(.{ .has_attr = .{ .base = left, .attrs = attrpath } });
                last_nonassoc = prec_hasattr;
                continue;
            }
            const info = infixInfo(t.kind) orelse break;
            if (info.prec < min_prec) break;
            if (last_nonassoc) |p| {
                if (p == info.prec) return error.UnexpectedToken;
            }
            _ = self.advance();
            const rhs_min: u8 = if (info.right_assoc) info.prec else info.prec + 1;
            const right = try self.parseExpression(rhs_min);
            left = switch (t.kind) {
                .eq => try self.allocExpr(.{ .op = .{ .kind = .eq, .left = left, .right = right } }),
                .neq => try self.allocExpr(.{ .op = .{ .kind = .neq, .left = left, .right = right } }),
                .and_ => try self.allocExpr(.{ .op = .{ .kind = .and_, .left = left, .right = right } }),
                .or_ => try self.allocExpr(.{ .op = .{ .kind = .or_, .left = left, .right = right } }),
                .impl => try self.allocExpr(.{ .op = .{ .kind = .impl, .left = left, .right = right } }),
                .update => try self.allocExpr(.{ .op = .{ .kind = .update, .left = left, .right = right } }),
                .concat => try self.allocExpr(.{ .op = .{ .kind = .concat_lists, .left = left, .right = right } }),
                .lt => try self.makeBuiltinCall("lessThan", &.{ left, right }),
                .gt => try self.makeBuiltinCall("lessThan", &.{ right, left }),
                .leq => blk: {
                    const call = try self.makeBuiltinCall("lessThan", &.{ right, left });
                    break :blk try self.allocExpr(.{ .not_ = call });
                },
                .geq => blk: {
                    const call = try self.makeBuiltinCall("lessThan", &.{ left, right });
                    break :blk try self.allocExpr(.{ .not_ = call });
                },
                .plus => blk: {
                    const parts = try self.alloc.alloc(*ast.Expr, 2);
                    parts[0] = left;
                    parts[1] = right;
                    break :blk try self.allocExpr(.{ .concat = .{ .parts = parts } });
                },
                .minus => try self.makeBuiltinCall("sub", &.{ left, right }),
                .star => try self.makeBuiltinCall("mul", &.{ left, right }),
                .slash => try self.makeBuiltinCall("div", &.{ left, right }),
                else => unreachable,
            };
            last_nonassoc = if (info.nonassoc) info.prec else null;
        }
        return left;
    }

    fn makeBuiltinCall(self: *Parser, name: []const u8, args: []const *ast.Expr) ParseError!*ast.Expr {
        const arr = try self.alloc.dupe(*ast.Expr, args);
        return self.allocExpr(.{ .call_builtin = .{ .name = name, .args = arr } });
    }

    fn canStartAppArg(t: Token) bool {
        return switch (t.kind) {
            .int, .float, .str, .indented, .path, .home_path, .spath, .uri, .lparen, .lbracket, .lbrace => true,
            .ident => {
                if (std.mem.eql(u8, t.text, "or")) return true;
                if (std.mem.eql(u8, t.text, "rec")) return true;
                if (std.mem.eql(u8, t.text, "let")) return true;
                return !lexer.isKeyword(t.text);
            },
            else => false,
        };
    }

    fn parseApp(self: *Parser) ParseError!*ast.Expr {
        var e = try self.parseSelect();
        while (Parser.canStartAppArg(self.peek())) {
            const arg = try self.parseSelect();
            e = try self.allocExpr(.{ .apply = .{ .fun = e, .arg = arg } });
        }
        return e;
    }

    fn parseSelect(self: *Parser) ParseError!*ast.Expr {
        var e = try self.parseSimple();
        while (true) {
            const t = self.peek();
            if (t.kind == .dot) {
                _ = self.advance();
                const attrpath = try self.parseAttrPath();
                var default: ?*ast.Expr = null;
                if (self.isIdent("or")) {
                    _ = self.advance();
                    default = try self.parseSelect();
                }
                e = try self.allocExpr(.{ .select = .{ .base = e, .attrs = attrpath, .default = default } });
                continue;
            }
            if (self.isIdent("or")) {
                // cursed `or`: `map or [...]` → `map (or) [...]`
                _ = self.advance();
                const or_var = try self.allocExpr(.{ .var_ref = "or" });
                e = try self.allocExpr(.{ .apply = .{ .fun = e, .arg = or_var } });
                continue;
            }
            break;
        }
        return e;
    }

    fn parseSimple(self: *Parser) ParseError!*ast.Expr {
        const t = self.peek();
        switch (t.kind) {
            .int => {
                _ = self.advance();
                return self.allocExpr(.{ .int = t.int_val });
            },
            .float => {
                _ = self.advance();
                return self.allocExpr(.{ .float = t.float_val });
            },
            .uri => {
                _ = self.advance();
                const parts = try self.alloc.alloc(ast.Part, 1);
                parts[0] = .{ .lit = t.text };
                return self.allocExpr(.{ .str = .{ .parts = parts, .kind = .dquote } });
            },
            .spath => {
                _ = self.advance();
                return self.allocExpr(.{ .import_path = t.text });
            },
            .str => {
                _ = self.advance();
                return self.strFromParts(t.parts, .dquote);
            },
            .indented => {
                _ = self.advance();
                return self.strFromParts(t.parts, .indented);
            },
            .path, .home_path => {
                _ = self.advance();
                return self.pathFromParts(t);
            },
            .lparen => {
                _ = self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.rparen);
                return e;
            },
            .lbracket => {
                _ = self.advance();
                var elems = std.array_list.Managed(*ast.Expr).init(self.alloc);
                while (self.peek().kind != .rbracket) {
                    const e = try self.parseSelect();
                    try elems.append(e);
                }
                _ = self.advance(); // ]
                return self.allocExpr(.{ .list = elems.items });
            },
            .lbrace => {
                const binds = try self.parseBinds(true);
                return self.allocExpr(.{ .attrset = .{ .binds = binds, .recursive = false } });
            },
            .ident => {
                if (self.isIdent("rec")) {
                    _ = self.advance();
                    const binds = try self.parseBinds(true);
                    return self.allocExpr(.{ .attrset = .{ .binds = binds, .recursive = true } });
                }
                if (self.isIdent("let")) {
                    _ = self.advance();
                    const binds = try self.parseBinds(false);
                    const attrs = try self.allocExpr(.{ .attrset = .{ .binds = binds, .recursive = true } });
                    return self.allocExpr(.{ .select = .{ .base = attrs, .attrs = &.{.{ .static = "body" }}, .default = null } });
                }
                if (lexer.isKeyword(t.text)) return error.UnexpectedToken;
                _ = self.advance();
                if (std.mem.eql(u8, t.text, "__curPos")) {
                    return self.allocExpr(.pos);
                }
                return self.allocExpr(.{ .var_ref = t.text });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn strFromParts(self: *Parser, parts: []const lexer.LPart, kind: ast.StrKind) ParseError!*ast.Expr {
        // Convert lexer parts to AST parts; interpolation token slices are
        // parsed as sub-expressions.
        var flat = std.array_list.Managed(ast.Part).init(self.alloc);
        var interps = std.array_list.Managed(*ast.Expr).init(self.alloc);
        for (parts) |p| {
            switch (p) {
                .lit => |l| {
                    if (kind == .indented) {
                        // handled by stripIndentation below (needs the
                        // raw parts, incl. counted flags)
                    } else {
                        try flat.append(.{ .lit = l.text });
                    }
                },
                .interp => |ts| {
                    if (kind == .indented) {
                        try interps.append(try self.parseSub(ts));
                    } else {
                        try flat.append(.{ .interp = try self.parseSub(ts) });
                    }
                },
            }
        }
        if (kind == .indented) {
            const stripped = try self.stripIndentation(parts, interps.items);
            return self.allocExpr(.{ .str = .{ .parts = stripped, .kind = .indented } });
        }
        return self.allocExpr(.{ .str = .{ .parts = flat.items, .kind = .dquote } });
    }

    /// Parse a token slice (an interpolation) as an expression.
    fn parseSub(self: *Parser, ts: []const Token) ParseError!*ast.Expr {
        var sub = Parser{
            .alloc = self.alloc,
            .toks = ts,
            .base_dir = self.base_dir,
            .home_dir = self.home_dir,
            .file = self.file,
        };
        return sub.parse();
    }

    /// Nix `ParserState::stripIndentation` — byte-for-byte behavior.
    fn stripIndentation(
        self: *Parser,
        parts: []const lexer.LPart,
        interps: []const *ast.Expr,
    ) ParseError![]const ast.Part {
        // Pass 1: compute minimum indentation.
        var at_start: bool = true;
        var min_indent: usize = 1000000;
        var cur_indent: usize = 0;
        for (parts) |p| {
            switch (p) {
                .interp => {
                    if (at_start) {
                        at_start = false;
                        if (cur_indent < min_indent) min_indent = cur_indent;
                    }
                },
                .lit => |l| {
                    if (!l.counted) {
                        if (at_start) {
                            at_start = false;
                            if (cur_indent < min_indent) min_indent = cur_indent;
                        }
                        continue;
                    }
                    for (l.text) |c| {
                        if (at_start) {
                            if (c == ' ') {
                                cur_indent += 1;
                            } else if (c == '\n') {
                                cur_indent = 0;
                            } else {
                                at_start = false;
                                if (cur_indent < min_indent) min_indent = cur_indent;
                            }
                        } else if (c == '\n') {
                            at_start = true;
                            cur_indent = 0;
                        }
                    }
                },
            }
        }
        if (min_indent == 1000000) min_indent = 0;

        // Pass 2: strip.
        var out = std.array_list.Managed(ast.Part).init(self.alloc);
        at_start = true;
        var cur_dropped: usize = 0;
        var ii2: usize = 0;
        var n = parts.len;
        for (parts) |p| {
            n -= 1;
            switch (p) {
                .interp => {
                    at_start = false;
                    cur_dropped = 0;
                    try out.append(.{ .interp = interps[ii2] });
                    ii2 += 1;
                },
                .lit => |l| {
                    if (!l.counted) {
                        at_start = false;
                        cur_dropped = 0;
                        if (l.text.len > 0) try out.append(.{ .lit = l.text });
                        continue;
                    }
                    var s2 = std.array_list.Managed(u8).init(self.alloc);
                    for (l.text) |c| {
                        if (at_start) {
                            if (c == ' ') {
                                if (cur_dropped >= min_indent) try s2.append(c);
                                cur_dropped += 1;
                            } else if (c == '\n') {
                                cur_dropped = 0;
                                try s2.append(c);
                            } else {
                                at_start = false;
                                cur_dropped = 0;
                                try s2.append(c);
                            }
                        } else {
                            try s2.append(c);
                            if (c == '\n') at_start = true;
                        }
                    }
                    // Remove the last line if it is empty (only spaces) —
                    // only when the whole string is a single literal part.
                    if (n == 0 and parts.len == 1) {
                        if (std.mem.lastIndexOfScalar(u8, s2.items, '\n')) |p_newline| {
                            var all_spaces = true;
                            for (s2.items[p_newline + 1 ..]) |c| {
                                if (c != ' ') {
                                    all_spaces = false;
                                    break;
                                }
                            }
                            if (all_spaces) s2.shrinkRetainingCapacity(p_newline + 1);
                        }
                    }
                    if (s2.items.len > 0) try out.append(.{ .lit = try self.alloc.dupe(u8, s2.items) });
                },
            }
        }
        return out.items;
    }

    fn pathFromParts(self: *Parser, t: Token) ParseError!*ast.Expr {
        // No interpolations: plain absolute path.
        var has_interp = false;
        for (t.parts) |p| {
            if (p == .interp) {
                has_interp = true;
                break;
            }
        }
        if (!has_interp) {
            const resolved = try self.resolvePath(t.kind, t.text);
            return self.allocExpr(.{ .path = resolved });
        }
        // Interpolated path: Concat with the resolved first segment as a
        // path, then strings/interps.
        var parts = std.array_list.Managed(*ast.Expr).init(self.alloc);
        const first_lit = switch (t.parts[0]) {
            .lit => |l| l.text,
            else => "",
        };
        const resolved = try self.resolvePath(t.kind, first_lit);
        try parts.append(try self.allocExpr(.{ .path = resolved }));
        for (t.parts[1..]) |p| {
            switch (p) {
                .lit => |l| {
                    const lit_parts = try self.alloc.alloc(ast.Part, 1);
                    lit_parts[0] = .{ .lit = l.text };
                    try parts.append(try self.allocExpr(.{ .str = .{ .parts = lit_parts, .kind = .dquote } }));
                },
                .interp => |ts| try parts.append(try self.parseSub(ts)),
            }
        }
        return self.allocExpr(.{ .concat = .{ .parts = parts.items } });
    }

    /// Resolve a path literal: absolute → canonPath; relative → against
    /// base_dir; home → home_dir + rest.  Trailing slash preserved.
    fn resolvePath(self: *Parser, kind: TokenKind, text: []const u8) ParseError![]const u8 {
        var full: []const u8 = undefined;
        if (kind == .home_path) {
            full = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ self.home_dir, text[1..] });
        } else if (text.len > 0 and text[0] == '/') {
            full = text;
        } else {
            full = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.base_dir, text });
        }
        const has_trailing = text.len > 1 and text[text.len - 1] == '/';
        const canon = try canonPath(self.alloc, full);
        if (has_trailing) {
            return std.fmt.allocPrint(self.alloc, "{s}/", .{canon});
        }
        return canon;
    }

    fn parseAttrPath(self: *Parser) ParseError![]const ast.AttrElem {
        var elems = std.array_list.Managed(ast.AttrElem).init(self.alloc);
        try elems.append(try self.parseAttr());
        while (self.peek().kind == .dot) {
            _ = self.advance();
            try elems.append(try self.parseAttr());
        }
        return elems.items;
    }

    fn parseAttr(self: *Parser) ParseError!ast.AttrElem {
        const t = self.peek();
        if (t.kind == .ident) {
            if (lexer.isKeyword(t.text) and !std.mem.eql(u8, t.text, "or")) return error.UnexpectedToken;
            _ = self.advance();
            return .{ .static = t.text };
        }
        if (t.kind == .str) {
            _ = self.advance();
            // attribute strings must be plain (no interpolation)
            if (t.parts.len != 1 or t.parts[0] != .lit) return error.UnexpectedToken;
            return .{ .static = t.parts[0].lit.text };
        }
        // dynamic: ${ expr }
        if (t.kind == .dollcurly) {
            _ = self.advance();
            const e = try self.parseExpr();
            _ = try self.expect(.rbrace);
            return .{ .dyn = e };
        }
        return error.UnexpectedToken;
    }

    fn parseBinds(self: *Parser, allow_dynamic_let: bool) ParseError![]const ast.AttrBind {
        return self.parseBindsMode(allow_dynamic_let, false);
    }

    fn parseBindsMode(self: *Parser, allow_dynamic_let: bool, is_let: bool) ParseError![]const ast.AttrBind {
        if (!is_let) _ = try self.expect(.lbrace);
        var binds = std.array_list.Managed(ast.AttrBind).init(self.alloc);
        while (true) {
            const t = self.peek();
            if (!is_let and t.kind == .rbrace) {
                _ = self.advance();
                break;
            }
            if (is_let and self.isIdent("in")) break;
            if (self.isIdent("inherit")) {
                const inherit_pos = self.peek();
                _ = self.advance();
                var from: ?*ast.Expr = null;
                if (self.peek().kind == .lparen) {
                    _ = self.advance();
                    from = try self.parseExpr();
                    _ = try self.expect(.rparen);
                }
                // names
                var names = std.array_list.Managed([]const u8).init(self.alloc);
                while (true) {
                    const nt = self.peek();
                    if (nt.kind == .ident) {
                        if (lexer.isKeyword(nt.text)) return error.UnexpectedToken;
                        _ = self.advance();
                        try names.append(nt.text);
                    } else if (nt.kind == .str) {
                        _ = self.advance();
                        if (nt.parts.len != 1 or nt.parts[0] != .lit) return error.UnexpectedToken;
                        try names.append(nt.parts[0].lit.text);
                    } else break;
                }
                _ = try self.expect(.semicolon);
                for (names.items) |name| {
                    const path = try self.alloc.alloc(ast.AttrElem, 1);
                    path[0] = .{ .static = name };
                    try binds.append(.{
                        .path = path,
                        .value = try self.allocExpr(.{ .var_ref = name }),
                        .inherit_from = from,
                        .pos = .{ .file = self.file, .line = @intCast(inherit_pos.line), .col = @intCast(inherit_pos.col) },
                    });
                }
                continue;
            }
            // attrpath '=' expr ';'
            const bind_pos = self.peek();
            const path = try self.parseAttrPath();
            if (!allow_dynamic_let) {
                for (path) |el| {
                    if (el == .dyn) return error.DynamicAttrsInLet;
                }
            }
            _ = try self.expect(.equals);
            const value = try self.parseExpr();
            _ = try self.expect(.semicolon);
            try binds.append(.{ .path = path, .value = value, .inherit_from = null, .pos = .{ .file = self.file, .line = @intCast(bind_pos.line), .col = @intCast(bind_pos.col) } });
        }
        return binds.items;
    }

    fn parseFormals(self: *Parser) ParseError!ast.Formals {
        _ = try self.expect(.lbrace);
        var formals = std.array_list.Managed(ast.Formal).init(self.alloc);
        var ellipsis = false;
        // `{ }`
        if (self.peek().kind == .rbrace) {
            _ = self.advance();
            return .{ .formals = &.{}, .ellipsis = false };
        }
        while (true) {
            const t = self.peek();
            if (t.kind == .ellipsis) {
                _ = self.advance();
                ellipsis = true;
                break;
            }
            if (t.kind != .ident) return error.ExpectedToken;
            _ = self.advance();
            var default: ?*ast.Expr = null;
            if (self.peek().kind == .question) {
                _ = self.advance();
                default = try self.parseExpr();
            }
            try formals.append(.{ .name = t.text, .default = default });
            if (self.peek().kind == .comma) {
                _ = self.advance();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        return .{ .formals = formals.items, .ellipsis = ellipsis };
    }

    /// Look ahead: is the `{` at the current position a formal set (i.e. is
    /// the matching `}` followed by `:`)?
    fn isBraceFormals(self: *Parser) bool {
        var depth: usize = 0;
        var j = self.i;
        while (j < self.toks.len) : (j += 1) {
            const t = self.toks[j];
            switch (t.kind) {
                .lbrace => depth += 1,
                .rbrace => {
                    depth -= 1;
                    if (depth == 0) {
                        const next = if (j + 1 < self.toks.len) self.toks[j + 1] else return false;
                        return next.kind == .colon or next.kind == .at;
                    }
                },
                else => {},
            }
        }
        return false;
    }
};

/// Lexical path normalization (Nix `canonPath`): collapse "." and "..".
pub fn canonPath(alloc: std.mem.Allocator, path: []const u8) ParseError![]const u8 {
    const absolute = path.len > 0 and path[0] == '/';
    var segs = std.array_list.Managed([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            continue;
        }
        try segs.append(seg);
    }
    if (absolute) {
        if (segs.items.len == 0) return "/";
        return std.fmt.allocPrint(alloc, "/{s}", .{std.mem.join(alloc, "/", segs.items) catch return error.OutOfMemory});
    }
    if (segs.items.len == 0) return ".";
    return std.mem.join(alloc, "/", segs.items);
}

test "parser basics" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "let x = 1; in x + 2";
    var lx = lexer.Lexer.init(a, src);
    const toks = try lx.lexAll();
    var p = Parser.init(a, toks, "/home/user", "/home/user");
    const e = try p.parse();
    try std.testing.expect(e.kind == .let_rec);
}

test "parser lambda and attrsets" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{ a, b ? 2, ... }@args: a + b + args.c";
    var lx = lexer.Lexer.init(a, src);
    const toks = try lx.lexAll();
    var p = Parser.init(a, toks, "/home/user", "/home/user");
    const e = try p.parse();
    try std.testing.expect(e.kind == .lambda);
    const lam = e.kind.lambda;
    try std.testing.expect(lam.formals != null);
    try std.testing.expectEqualStrings("args", lam.arg_name.?);
}

test "parser stripIndentation" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "''\n  hello\n  world\n''";
    var lx = lexer.Lexer.init(a, src);
    const toks = try lx.lexAll();
    try std.testing.expectEqual(TokenKind.indented, toks[0].kind);
    var p = Parser.init(a, toks, "/home/user", "/home/user");
    const e = try p.parse();
    try std.testing.expect(e.kind == .str);
    try std.testing.expectEqual(@as(usize, 1), e.kind.str.parts.len);
    try std.testing.expectEqualStrings("hello\nworld\n", e.kind.str.parts[0].lit);
}

test "parser precedence" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // `!` binds looser than `+`:  !a + b  ==  !(a + b)
    var lx = lexer.Lexer.init(a, "!a + b");
    const toks = try lx.lexAll();
    var p = Parser.init(a, toks, "/home/user", "/home/user");
    const e = try p.parse();
    try std.testing.expect(e.kind == .not_);
    try std.testing.expect(e.kind.not_.kind == .concat);

    // `-` binds tighter than `*`:  -a * b  ==  (-a) * b
    lx = lexer.Lexer.init(a, "-a * b");
    const toks2 = try lx.lexAll();
    p = Parser.init(a, toks2, "/home/user", "/home/user");
    const e2 = try p.parse();
    try std.testing.expect(e2.kind == .call_builtin); // mul
    const mul = e2.kind.call_builtin;
    try std.testing.expectEqualStrings("mul", mul.name);
    try std.testing.expect(mul.args[0].kind == .call_builtin); // sub 0 a
}
