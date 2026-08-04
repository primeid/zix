//! Lexer for the Nix expression language, faithful to Nix 2.34's
//! `lexer.l` (token-level compatibility, including path/URI edge cases).

const std = @import("std");

pub const TokenKind = enum {
    eof,
    ident,
    int,
    float,
    str, // "..." with parts
    indented, // ''...'' with parts (stripIndentation applied by parser)
    path, // absolute/relative path, may contain interpolation parts
    home_path, // ~/... path
    spath, // <...>
    uri, // scheme:body → string literal
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    semicolon,
    colon,
    comma,
    dot,
    ellipsis,
    question,
    at,
    plus,
    minus,
    star,
    slash,
    eq,
    neq,
    lt,
    gt,
    leq,
    geq,
    equals,
    and_,
    or_,
    impl,
    update,
    concat,
    not_,
    pipe_from,
    pipe_into,
    dollcurly, // ${ at top level (dynamic attr paths / binds)
};

pub const LPart = union(enum) {
    lit: struct { text: []const u8, counted: bool },
    interp: []const Token,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    int_val: i64 = 0,
    float_val: f64 = 0,
    parts: []const LPart = &.{},
    line: usize,
    col: usize,
};

pub const LexError = error{
    OutOfMemory,
    UnterminatedString,
    UnterminatedIndentedString,
    UnterminatedInterpolation,
    InvalidChar,
    InvalidInteger,
    InvalidFloat,
    PathTrailingSlash,
};

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .alloc = alloc, .src = src };
    }

    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn peek(self: *const Lexer, off: usize) ?u8 {
        if (self.pos + off >= self.src.len) return null;
        return self.src[self.pos + off];
    }

    fn isPathChar(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-', '+' => true,
            else => false,
        };
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9') or c == '\'' or c == '-';
    }

    fn isUriSchemeChar(c: u8) bool {
        return isIdentChar(c) and c != '\'';
    }

    fn isUriBodyChar(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '%', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'' => true,
            else => false,
        };
    }

    pub fn lexAll(self: *Lexer) LexError![]const Token {
        var toks = std.array_list.Managed(Token).init(self.alloc);
        while (true) {
            const t = try self.nextToken();
            const n = try toks.addOne();
            n.* = t;
            if (t.kind == .eof) break;
        }
        return toks.items;
    }

    fn pushToken(self: *Lexer, kind: TokenKind, text: []const u8) Token {
        return .{ .kind = kind, .text = text, .line = self.line, .col = self.col };
    }

    fn nextToken(self: *Lexer) LexError!Token {
        while (true) {
            const c = self.peek(0) orelse return self.pushToken(.eof, "");
            switch (c) {
                ' ', '\t', '\r', '\n' => _ = self.advance(),
                '#' => {
                    while (self.peek(0) != null) {
                        if (self.peek(0).? == '\n') break;
                        _ = self.advance();
                    }
                },
                else => break,
            }
        }
        // Block comments /* ... */ (non-nesting, like Nix).
        if (self.peek(0) == '/' and self.peek(1) == '*') {
            _ = self.advance();
            _ = self.advance();
            var prev: ?u8 = null;
            while (self.peek(0) != null) {
                const ch = self.advance();
                if (prev == '*' and ch == '/') return self.nextToken();
                prev = ch;
            }
            return error.InvalidChar;
        }

        const c = self.peek(0).?;
        const line = self.line;
        const col = self.col;

        switch (c) {
            '{' => {
                _ = self.advance();
                return .{ .kind = .lbrace, .text = "", .line = line, .col = col };
            },
            '}' => {
                _ = self.advance();
                return .{ .kind = .rbrace, .text = "", .line = line, .col = col };
            },
            '(' => {
                _ = self.advance();
                return .{ .kind = .lparen, .text = "", .line = line, .col = col };
            },
            ')' => {
                _ = self.advance();
                return .{ .kind = .rparen, .text = "", .line = line, .col = col };
            },
            '[' => {
                _ = self.advance();
                return .{ .kind = .lbracket, .text = "", .line = line, .col = col };
            },
            ']' => {
                _ = self.advance();
                return .{ .kind = .rbracket, .text = "", .line = line, .col = col };
            },
            ';' => {
                _ = self.advance();
                return .{ .kind = .semicolon, .text = "", .line = line, .col = col };
            },
            ':' => {
                _ = self.advance();
                return .{ .kind = .colon, .text = "", .line = line, .col = col };
            },
            ',' => {
                _ = self.advance();
                return .{ .kind = .comma, .text = "", .line = line, .col = col };
            },
            '@' => {
                _ = self.advance();
                return .{ .kind = .at, .text = "", .line = line, .col = col };
            },
            '?' => {
                _ = self.advance();
                return .{ .kind = .question, .text = "", .line = line, .col = col };
            },
            '!' => {
                _ = self.advance();
                if (self.peek(0) == '=') {
                    _ = self.advance();
                    return .{ .kind = .neq, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .not_, .text = "", .line = line, .col = col };
            },
            '=' => {
                _ = self.advance();
                if (self.peek(0) == '=') {
                    _ = self.advance();
                    return .{ .kind = .eq, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .equals, .text = "", .line = line, .col = col };
            },
            '<' => {
                // spath: <pathchar+[/...]>
                if (self.matchSpath()) |inner| {
                    return .{ .kind = .spath, .text = inner, .line = line, .col = col };
                }
                _ = self.advance();
                if (self.peek(0) == '=') {
                    _ = self.advance();
                    return .{ .kind = .leq, .text = "", .line = line, .col = col };
                }
                if (self.peek(0) == '|') {
                    _ = self.advance();
                    return .{ .kind = .pipe_from, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .lt, .text = "", .line = line, .col = col };
            },
            '>' => {
                _ = self.advance();
                if (self.peek(0) == '=') {
                    _ = self.advance();
                    return .{ .kind = .geq, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .gt, .text = "", .line = line, .col = col };
            },
            '&' => {
                _ = self.advance();
                if (self.peek(0) == '&') {
                    _ = self.advance();
                    return .{ .kind = .and_, .text = "", .line = line, .col = col };
                }
                return error.InvalidChar;
            },
            '|' => {
                _ = self.advance();
                if (self.peek(0) == '|') {
                    _ = self.advance();
                    return .{ .kind = .or_, .text = "", .line = line, .col = col };
                }
                if (self.peek(0) == '>') {
                    _ = self.advance();
                    return .{ .kind = .pipe_into, .text = "", .line = line, .col = col };
                }
                return error.InvalidChar;
            },
            '-' => {
                _ = self.advance();
                if (self.peek(0) == '>') {
                    _ = self.advance();
                    return .{ .kind = .impl, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .minus, .text = "", .line = line, .col = col };
            },
            '+' => {
                _ = self.advance();
                if (self.peek(0) == '+') {
                    _ = self.advance();
                    return .{ .kind = .concat, .text = "", .line = line, .col = col };
                }
                return .{ .kind = .plus, .text = "", .line = line, .col = col };
            },
            '*' => {
                _ = self.advance();
                return .{ .kind = .star, .text = "", .line = line, .col = col };
            },
            '/' => {
                if (self.peek(1) == '/') {
                    _ = self.advance();
                    _ = self.advance();
                    return .{ .kind = .update, .text = "", .line = line, .col = col };
                }
                if (try self.matchPathToken(false)) |tok| return tok;
                _ = self.advance();
                return .{ .kind = .slash, .text = "", .line = line, .col = col };
            },
            '~' => {
                if (try self.matchPathToken(true)) |tok| return tok;
                return error.InvalidChar;
            },
            '"' => return self.lexString(),
            '\'' => {
                if (self.peek(1) == '\'') return self.lexIndented();
                return error.InvalidChar;
            },
            '$' => {
                if (self.peek(1) == '{') {
                    _ = self.advance();
                    _ = self.advance();
                    return .{ .kind = .dollcurly, .text = "", .line = line, .col = col };
                }
                return error.InvalidChar;
            },
            '.' => {
                if (self.peek(1) == '.' and self.peek(2) == '.') {
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    return .{ .kind = .ellipsis, .text = "", .line = line, .col = col };
                }
                if (try self.matchPathToken(false)) |tok| return tok;
                // .5-style float literal
                if (self.peek(1)) |c2| {
                    if (c2 >= '0' and c2 <= '9') {
                        const start = self.pos;
                        _ = self.advance(); // .
                        if (self.matchFloatFrom(start)) |f| {
                            return .{ .kind = .float, .text = self.src[start..self.pos], .float_val = f, .line = line, .col = col };
                        }
                    }
                }
                _ = self.advance();
                return .{ .kind = .dot, .text = "", .line = line, .col = col };
            },
            else => {},
        }

        // URI literal: [a-zA-Z][a-zA-Z0-9+-.]*:[body+]
        if (isIdentStart(c)) {
            if (self.matchUri()) |uri| {
                return .{ .kind = .uri, .text = uri, .line = line, .col = col };
            }
            // a/b style paths beat identifiers (flex longest match)
            if (try self.matchPathToken(false)) |tok| return tok;
        }

        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.peek(0)) |c2| {
                if (!isIdentChar(c2)) break;
                _ = self.advance();
            }
            const text = self.src[start..self.pos];
            return .{ .kind = .ident, .text = text, .line = line, .col = col };
        }

        if (c >= '0' and c <= '9') {
            // Path may win over number: "1/2" is a path.
            if (try self.matchPathToken(false)) |tok| return tok;
            const start = self.pos;
            while (self.peek(0)) |c2| {
                if (c2 < '0' or c2 > '9') break;
                _ = self.advance();
            }
            // Float?
            if (self.matchFloatFrom(start)) |f| {
                return .{ .kind = .float, .text = self.src[start..self.pos], .float_val = f, .line = line, .col = col };
            }
            const text = self.src[start..self.pos];
            const v = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger;
            return .{ .kind = .int, .text = text, .int_val = v, .line = line, .col = col };
        }

        return error.InvalidChar;
    }

    /// After consuming the integer digits `[start, pos)`, check for a
    /// float tail: `(\.[0-9]*)?([Ee][+-]?[0-9]+)?` per Nix's FLOAT regex.
    /// Returns the float value if a full match was consumed.
    fn matchFloatFrom(self: *Lexer, start: usize) ?f64 {
        const save = self.pos;
        const save_col = self.col;
        // mantissa: ([1-9][0-9]*\.[0-9]*)|(0?\.[0-9]+) — we already consumed
        // the integer part; Nix requires the dot in the mantissa.
        if (self.peek(0) != '.') return null;
        _ = self.advance();
        while (self.peek(0)) |c| {
            if (c < '0' or c > '9') break;
            _ = self.advance();
        }
        // exponent
        if (self.peek(0)) |c| {
            if (c == 'e' or c == 'E') {
                const save2 = self.pos;
                _ = self.advance();
                if (self.peek(0)) |s| {
                    if (s == '+' or s == '-') _ = self.advance();
                }
                var any_digit = false;
                while (self.peek(0)) |c2| {
                    if (c2 < '0' or c2 > '9') break;
                    any_digit = true;
                    _ = self.advance();
                }
                if (!any_digit) self.pos = save2;
            }
        }
        const text = self.src[start..self.pos];
        // Nix's regex requires at least one digit after the dot OR
        // at least one digit after the dot when the int part is 0 — we
        // approximated; re-validate against the exact regex.
        if (!validFloatRegex(text)) {
            self.pos = save;
            self.col = save_col;
            return null;
        }
        const v = std.fmt.parseFloat(f64, text) catch {
            self.pos = save;
            self.col = save_col;
            return null;
        };
        return v;
    }

    fn validFloatRegex(text: []const u8) bool {
        // (( [1-9][0-9]*\.[0-9]* ) | ( 0?\.[0-9]+ )) ([Ee][+-]?[0-9]+)?
        const n = std.mem.indexOfScalar(u8, text, 'e') orelse std.mem.indexOfScalar(u8, text, 'E');
        const mant = if (n) |i| text[0..i] else text;
        const dot = std.mem.indexOfScalar(u8, mant, '.') orelse return false;
        const int_part = mant[0..dot];
        const frac_part = mant[dot + 1 ..];
        // `0?\.[0-9]+`: a single leading zero (or no integer part) requires
        // at least one fraction digit (`0.` is invalid, `.` alone is invalid).
        if (int_part.len == 0 or (int_part.len == 1 and int_part[0] == '0')) {
            return frac_part.len > 0;
        }
        // `[1-9][0-9]*\.[0-9]*`: trailing-dot floats are allowed (`10.` = 10).
        if (int_part[0] < '1' or int_part[0] > '9') return false;
        return true;
    }

    fn matchUri(self: *Lexer) ?[]const u8 {
        const start = self.pos;
        var i = self.pos;
        // scheme
        while (i < self.src.len and isUriSchemeChar(self.src[i])) i += 1;
        if (i >= self.src.len or self.src[i] != ':') return null;
        i += 1;
        // body: at least one char
        if (i >= self.src.len or !isUriBodyChar(self.src[i])) return null;
        while (i < self.src.len and isUriBodyChar(self.src[i])) i += 1;
        const text = self.src[start..i];
        self.pos = i;
        self.col += i - start;
        return text;
    }

    fn matchSpath(self: *Lexer) ?[]const u8 {
        const start = self.pos;
        if (self.src[start] != '<') return null;
        var i = start + 1;
        // {PATH_CHAR}+ (\/{PATH_CHAR}+)*
        var n: usize = 0;
        while (i < self.src.len and isPathChar(self.src[i])) : (i += 1) n += 1;
        if (n == 0) return null;
        while (i < self.src.len and self.src[i] == '/') {
            i += 1;
            n = 0;
            while (i < self.src.len and isPathChar(self.src[i])) : (i += 1) n += 1;
            if (n == 0) return null;
        }
        if (i >= self.src.len or self.src[i] != '>') return null;
        const inner = self.src[start + 1 .. i];
        self.pos = i + 1;
        self.col += (i + 1) - start;
        return inner;
    }

    /// Try to match a path literal starting at the current position.
    /// On success returns the token and advances; else null (position
    /// unchanged).
    fn matchPathToken(self: *Lexer, home: bool) LexError!?Token {
        const line = self.line;
        const col = self.col;
        const start = self.pos;
        const save_col = self.col;
        const save_line = self.line;
        if (home) {
            if (self.peek(0) != '~') return null;
            if (self.peek(1) != '/') return null;
            _ = self.advance(); // ~ (the '/' is handled by the shared logic)
        }
        var parts = std.array_list.Managed(LPart).init(self.alloc);
        var lit = std.array_list.Managed(u8).init(self.alloc);
        var segs: usize = 0;

        // initial PATH_CHAR* run
        while (self.peek(0)) |c| {
            if (!isPathChar(c)) break;
            lit.append(c) catch return error.OutOfMemory;
            _ = self.advance();
        }
        while (true) {
            // `${` directly after a slash: PATH_SEG rule
            if (self.peek(0) == '/' and self.peek(1) == '$' and self.peek(2) == '{') {
                lit.append('/') catch return error.OutOfMemory;
                _ = self.advance();
                segs += 1;
                break;
            }
            if (self.peek(0) != '/') break;
            // slash must be followed by a segment char (else it's the DIV token)
            const next = self.peek(1) orelse break;
            if (!isPathChar(next)) break;
            lit.append('/') catch return error.OutOfMemory;
            _ = self.advance();
            while (self.peek(0)) |c| {
                if (!isPathChar(c)) break;
                lit.append(c) catch return error.OutOfMemory;
                _ = self.advance();
            }
            segs += 1;
        }
        if (segs == 0) {
            self.pos = start;
            self.col = save_col;
            self.line = save_line;
            return null;
        }
        // optional trailing slash
        if (self.peek(0) == '/') {
            lit.append('/') catch return error.OutOfMemory;
            _ = self.advance();
        }

        try parts.append(.{ .lit = .{ .text = try self.alloc.dupe(u8, lit.items), .counted = true } });

        // interpolations inside paths: /${...}segments
        while (self.peek(0) == '$' and self.peek(1) == '{') {
            _ = self.advance();
            _ = self.advance();
            const interp = try self.lexInterpolation();
            try parts.append(.{ .interp = interp });
            // continue with PATH_CHARs and slash-segments
            var lit2 = std.array_list.Managed(u8).init(self.alloc);
            while (self.peek(0)) |c| {
                if (!isPathChar(c)) break;
                lit2.append(c) catch return error.OutOfMemory;
                _ = self.advance();
            }
            if (self.peek(0) == '/') {
                if (self.peek(1) == '$' and self.peek(2) == '{') {
                    lit2.append('/') catch return error.OutOfMemory;
                    _ = self.advance();
                    try parts.append(.{ .lit = .{ .text = try self.alloc.dupe(u8, lit2.items), .counted = true } });
                    continue; // another interpolation
                }
                if (self.peek(1)) |c2| {
                    if (isPathChar(c2)) {
                        // segment continues
                        lit2.append('/') catch return error.OutOfMemory;
                        _ = self.advance();
                        while (self.peek(0)) |c3| {
                            if (!isPathChar(c3)) break;
                            lit2.append(c3) catch return error.OutOfMemory;
                            _ = self.advance();
                        }
                    } else {
                        return error.PathTrailingSlash;
                    }
                } else {
                    return error.PathTrailingSlash;
                }
            }
            if (lit2.items.len > 0) {
                try parts.append(.{ .lit = .{ .text = try self.alloc.dupe(u8, lit2.items), .counted = true } });
            }
        }

        const text = self.src[start..self.pos];
        const tok = Token{
            .kind = if (home) .home_path else .path,
            .text = text,
            .parts = parts.items,
            .line = line,
            .col = col,
        };
        return tok;
    }

    fn lexString(self: *Lexer) LexError!Token {
        const line = self.line;
        const col = self.col;
        _ = self.advance(); // "
        var parts = std.array_list.Managed(LPart).init(self.alloc);
        var lit = std.array_list.Managed(u8).init(self.alloc);
        while (true) {
            const c = self.peek(0) orelse return error.UnterminatedString;
            if (c == '"') {
                _ = self.advance();
                break;
            }
            if (c == '\\') {
                _ = self.advance();
                const e = self.peek(0) orelse return error.UnterminatedString;
                _ = self.advance();
                switch (e) {
                    'n' => try lit.append('\n'),
                    'r' => try lit.append('\r'),
                    't' => try lit.append('\t'),
                    else => try lit.append(e),
                }
                continue;
            }
            if (c == '$' and self.peek(1) == '{') {
                if (lit.items.len > 0) {
                    try parts.append(.{ .lit = .{ .text = try self.alloc.dupe(u8, lit.items), .counted = true } });
                    lit.clearRetainingCapacity();
                }
                _ = self.advance();
                _ = self.advance();
                const interp = try self.lexInterpolation();
                try parts.append(.{ .interp = interp });
                continue;
            }
            _ = self.advance();
            if (c == '\r') {
                try lit.append('\n');
                if (self.peek(0) == '\n') _ = self.advance();
            } else {
                try lit.append(c);
            }
        }
        if (lit.items.len > 0) {
            try parts.append(.{ .lit = .{ .text = try self.alloc.dupe(u8, lit.items), .counted = true } });
        }
        return Token{ .kind = .str, .text = "", .parts = parts.items, .line = line, .col = col };
    }

    fn lexIndented(self: *Lexer) LexError!Token {
        const line = self.line;
        const col = self.col;
        _ = self.advance(); // '
        _ = self.advance(); // '
        // optional spaces + newline (part of the open token)
        while (self.peek(0) == ' ') _ = self.advance();
        if (self.peek(0) == '\n') _ = self.advance();

        var parts = std.array_list.Managed(LPart).init(self.alloc);
        var lit = std.array_list.Managed(u8).init(self.alloc);
        var counted = true;
        var lit_dirty = false;

        const flush = struct {
            fn f(
                alloc: std.mem.Allocator,
                parts_list: *std.array_list.Managed(LPart),
                lit_buf: *std.array_list.Managed(u8),
                cnt: bool,
                dirty: *bool,
            ) LexError!void {
                if (lit_buf.items.len > 0 or !cnt) {
                    try parts_list.append(.{ .lit = .{ .text = try alloc.dupe(u8, lit_buf.items), .counted = cnt } });
                    lit_buf.clearRetainingCapacity();
                }
                dirty.* = false;
            }
        }.f;

        while (true) {
            const c = self.peek(0) orelse return error.UnterminatedIndentedString;
            if (c == '\'' and self.peek(1) == '\'') {
                if (self.peek(2) == '\'') {
                    // ''' → ''
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                    try lit.appendSlice("''");
                    counted = false;
                    lit_dirty = true;
                    continue;
                }
                if (self.peek(2) == '$') {
                    // ''$ → $
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                    try lit.append('$');
                    counted = false;
                    lit_dirty = true;
                    continue;
                }
                if (self.peek(2) == '\\') {
                    // ''\X → escape
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    const e = self.peek(0) orelse return error.UnterminatedIndentedString;
                    _ = self.advance();
                    try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                    switch (e) {
                        'n' => try lit.append('\n'),
                        'r' => try lit.append('\r'),
                        't' => try lit.append('\t'),
                        else => try lit.append(e),
                    }
                    counted = false;
                    lit_dirty = true;
                    continue;
                }
                // '' → close
                _ = self.advance();
                _ = self.advance();
                break;
            }
            if (c == '$' and self.peek(1) == '{') {
                _ = self.advance();
                _ = self.advance();
                try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                const interp = try self.lexInterpolation();
                try parts.append(.{ .interp = interp });
                counted = true;
                continue;
            }
            if (c == '$') {
                // lone $ (not followed by { or ') → separate (counted=false)
                _ = self.advance();
                try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                try lit.append('$');
                counted = false;
                lit_dirty = true;
                continue;
            }
            _ = self.advance();
            if (!counted) {
                // raw char following an escape: start a new counted run
                try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
                counted = true;
            }
            try lit.append(c);
            lit_dirty = true;
        }
        try flush(self.alloc, &parts, &lit, counted, &lit_dirty);
        return Token{ .kind = .indented, .text = "", .parts = parts.items, .line = line, .col = col };
    }

    /// Lex tokens for a `${...}` interpolation, stopping after the
    /// matching `}` (which is consumed).  Returns the token slice.
    fn lexInterpolation(self: *Lexer) LexError![]const Token {
        // The interpolation content is a full expression; braces are counted
        // from the token stream so that whitespace or operators around a
        // closing `}` are handled correctly (e.g. multi-line `${ expr }`).
        var toks = std.array_list.Managed(Token).init(self.alloc);
        var depth: usize = 1;
        while (depth > 0) {
            const t = try self.nextToken();
            switch (t.kind) {
                .eof => return error.UnterminatedInterpolation,
                .lbrace, .dollcurly => {
                    depth += 1;
                    try toks.append(t);
                },
                .rbrace => {
                    depth -= 1;
                    if (depth > 0) try toks.append(t);
                },
                else => try toks.append(t),
            }
        }
        return toks.items;
    }
};

const Keyword = struct { kw: []const u8 };
const keywords = [_]Keyword{
    .{ .kw = "if" }, .{ .kw = "then" }, .{ .kw = "else" }, .{ .kw = "assert" },
    .{ .kw = "with" }, .{ .kw = "let" }, .{ .kw = "in" }, .{ .kw = "rec" },
    .{ .kw = "inherit" },
    // "or" is contextual (usable as identifier), handled by the parser.
};

pub fn isKeyword(text: []const u8) bool {
    for (keywords) |k| {
        if (std.mem.eql(u8, k.kw, text)) return true;
    }
    return false;
}

test "lexer basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(arena.allocator(), "let x = 1; in x + 2 // { a = \"hi\"; }");
    const toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqualStrings("let", toks[0].text);
    try std.testing.expectEqual(TokenKind.eof, toks[toks.len - 1].kind);
}

test "lexer path vs division" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = Lexer.init(a, "a/b");
    var toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.path, toks[0].kind);
    try std.testing.expectEqualStrings("a/b", toks[0].text);

    l = Lexer.init(a, "a / b");
    toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.slash, toks[1].kind);
    try std.testing.expectEqual(TokenKind.ident, toks[2].kind);

    l = Lexer.init(a, "./foo/../bar");
    toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.path, toks[0].kind);

    l = Lexer.init(a, "/nix/store/x");
    toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.path, toks[0].kind);

    l = Lexer.init(a, "~/foo");
    toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.home_path, toks[0].kind);
}

test "lexer string interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(arena.allocator(), "\"a${x}b${y + 1}c\"");
    const toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.str, toks[0].kind);
    try std.testing.expectEqual(@as(usize, 5), toks[0].parts.len);
    try std.testing.expectEqual(TokenKind.ident, toks[0].parts[1].interp[0].kind);
    try std.testing.expectEqual(TokenKind.plus, toks[0].parts[3].interp[1].kind);
}

test "lexer indented string escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(arena.allocator(), "''\n  a''$b'''c''${d}''");
    const toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.indented, toks[0].kind);
}

test "lexer uri vs lambda" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = Lexer.init(a, "x:y");
    var toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.uri, toks[0].kind);
    try std.testing.expectEqualStrings("x:y", toks[0].text);

    l = Lexer.init(a, "x: y");
    toks = try l.lexAll();
    try std.testing.expectEqual(TokenKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokenKind.colon, toks[1].kind);
}
