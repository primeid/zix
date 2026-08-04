const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const fsutil = @import("fsutil.zig");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fsutil.io = std.Options.debug_io;
    const src = fsutil.readFileAlloc(a, "/tmp/nixpkgs/nixpkgs-26.11pre1046984.104240a77242/lib/default.nix", 1 << 30) catch return;
    var lx = lexer.Lexer.init(a, src);
    const toks = try lx.lexAll();
    var p = parser.Parser.init(a, toks, "/tmp", "/home/u");
    const e = try p.parse();
    try walk(e);
    std.debug.print("done\n", .{});
}
fn walk(e: *const ast.Expr) !void {
    if (e.pos.line == 41 or e.pos.line == 14 or e.pos.line == 43) {
        std.debug.print("node {s} at {d}:{d}\n", .{ @tagName(e.kind), e.pos.line, e.pos.col });
    }
    switch (e.kind) {
        .str => |s| for (s.parts) |part| switch (part) {
            .lit => {},
            .interp => |x| try walk(x),
        },
        .select => |sel| {
            try walk(sel.base);
            if (sel.default) |d| try walk(d);
        },
        .has_attr => |ha| try walk(ha.base),
        .op => |o| {
            try walk(o.left);
            try walk(o.right);
        },
        .not_ => |n| try walk(n),
        .apply => |ap| {
            try walk(ap.fun);
            try walk(ap.arg);
        },
        .call_builtin => |cb| for (cb.args) |x| try walk(x),
        .lambda => |lam| try walk(lam.body),
        .let_rec => |lr| {
            for (lr.binds) |b| {
                if (b.inherit_from) |f| try walk(f);
                try walk(b.value);
            }
            try walk(lr.body);
        },
        .attrset => |at| for (at.binds) |b| {
            if (b.inherit_from) |f| try walk(f);
            try walk(b.value);
        },
        .if_ => |i| {
            try walk(i.cond);
            try walk(i.then);
            try walk(i.else_);
        },
        .assert_ => |a| {
            try walk(a.cond);
            try walk(a.body);
        },
        .with_ => |w| {
            try walk(w.attrs);
            try walk(w.body);
        },
        else => {},
    }
}
