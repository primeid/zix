//! ZIX — the Nix expression language in Zig.
//!
//! Usage:
//!   zix eval [--raw] [--read-only] [--store-dir DIR] [-I path] FILE
//!   zix eval [--raw] -E 'expr'
//!   zix parse FILE        (lex + parse, print nothing on success)

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const eval = zix.eval;
const value = zix.value;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();

    var args_iter = switch (builtin.os.tag) {
        .windows => try std.process.Args.Iterator.initAllocator(init.minimal.args, a),
        else => std.process.Args.Iterator.init(init.minimal.args),
    };
    defer args_iter.deinit();
    var argv = std.array_list.Managed([]const u8).init(a);
    while (args_iter.next()) |arg| {
        try argv.append(try a.dupe(u8, arg));
    }

    var target: ?[]const u8 = null;
    var mode: enum { eval, parse } = .eval;
    var expr_mode = false;
    var raw = false;
    var read_only = false;
    var store_dir: []const u8 = init.environ_map.get("ZIX_STORE_DIR") orelse "/nix/store";
    var nix_path_extra = std.array_list.Managed([]const u8).init(a);

    var i: usize = 1;
    while (i < argv.items.len) : (i += 1) {
        const arg = argv.items[i];
        if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--expr")) {
            expr_mode = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, arg, "--store-dir")) {
            i += 1;
            if (i >= argv.items.len) {
                std.debug.print("zix: missing argument for --store-dir\n", .{});
                std.process.exit(1);
            }
            store_dir = argv.items[i];
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= argv.items.len) {
                std.debug.print("zix: missing argument for -I\n", .{});
                std.process.exit(1);
            }
            try nix_path_extra.append(argv.items[i]);
        } else if (std.mem.eql(u8, arg, "parse")) {
            mode = .parse;
        } else if (std.mem.eql(u8, arg, "eval")) {
            mode = .eval;
        } else if (target == null and expr_mode) {
            target = arg; // expression following -E (may start with '-')
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zix: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            target = arg;
        }
    }

    const home_dir = init.environ_map.get("HOME") orelse "/";
    const st = try eval.EvalState.init(a, store_dir, read_only, home_dir);
    defer st.deinit();
    st.environ = init.environ_map;
    st.nix_path = try parseNixPath(a, init.environ_map, nix_path_extra.items);

    const target_str = target orelse {
        std.debug.print("zix: missing file or expression argument\n", .{});
        std.process.exit(1);
    };

    if (mode == .parse) {
        const contents = readFileOrExit(a, target_str);
        _ = st.parse(contents, target_str) catch |e| {
            std.debug.print("zix: parse error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        return;
    }

    var output = std.array_list.Managed(u8).init(a);
    const RunCtx = struct {
        st: *eval.EvalState,
        parsed: *const zix.ast.Expr,
        output: *std.array_list.Managed(u8),
        raw: bool,
    };
    // Evaluate AND print on a thread with a large stack: deep forcing of
    // the (lazy) result must not overflow the small main-thread stack.
    const run_eval = struct {
        fn f(ctx: RunCtx) void {
            var result = ctx.st.eval(ctx.parsed, ctx.st.base_env, 0) catch |e| exitEvalError(e, ctx.st);
            printValue(ctx.st, &result, ctx.output, 0, ctx.raw) catch |e| {
                if (ctx.st.err_msg.len > 0) {
                    std.debug.print("zix: error printing value: {s}\n", .{ctx.st.err_msg});
                } else {
                    std.debug.print("zix: error printing value: {s}\n", .{@errorName(e)});
                }
                std.process.exit(1);
            };
        }
    }.f;
    if (expr_mode) {
        const cwd = fsutilRealpathCwd(a);
        const vfile = try std.fmt.allocPrint(a, "{s}/<command-line>", .{cwd});
        const parsed = st.parse(target_str, vfile) catch |e| {
            if (st.err_msg.len > 0) {
                std.debug.print("zix: parse error: {s}\n", .{st.err_msg});
            } else {
                std.debug.print("zix: parse error: {s}\n", .{@errorName(e)});
            }
            std.process.exit(1);
        };
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run_eval, .{ RunCtx{ .st = st, .parsed = parsed, .output = &output, .raw = raw } });
        t.join();
    } else {
        const parsed = st.parseFile(target_str) catch |e| exitEvalError(e, st);
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run_eval, .{ RunCtx{ .st = st, .parsed = parsed, .output = &output, .raw = raw } });
        t.join();
    }

    try output.append('\n');
    writeStdout(output.items);
}

fn exitEvalError(e: anyerror, st: *eval.EvalState) noreturn {
    if (st.err_msg.len > 0) {
        std.debug.print("zix: error: {s}\n", .{st.err_msg});
    } else {
        std.debug.print("zix: error: {s}\n", .{@errorName(e)});
    }
    std.process.exit(1);
}

fn fsutilRealpathCwd(a: std.mem.Allocator) []const u8 {
    return zix.fsutil.readLinkAlloc(a, "/proc/self/cwd") catch ".";
}

fn readFileOrExit(a: std.mem.Allocator, path: []const u8) []const u8 {
    return zix.fsutil.readFileAlloc(a, path, 1 << 30) catch |e| {
        std.debug.print("zix: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        std.process.exit(1);
    };
}

fn writeStdout(bytes: []const u8) void {
    std.Io.File.writeStreamingAll(.stdout(), zix.fsutil.io, bytes) catch return;
}

fn parseNixPath(
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    extra: []const []const u8,
) ![]const eval.NixPathEntry {
    var entries = std.array_list.Managed(eval.NixPathEntry).init(a);
    // -I entries take priority over NIX_PATH, like `nix`.
    for (extra) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            try entries.append(.{ .prefix = entry[0..eq], .path = entry[eq + 1 ..] });
        } else {
            try entries.append(.{ .prefix = "", .path = entry });
        }
    }
    if (environ.get("NIX_PATH")) |np| {
        var it = std.mem.tokenizeScalar(u8, np, ':');
        while (it.next()) |entry| {
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                try entries.append(.{ .prefix = entry[0..eq], .path = entry[eq + 1 ..] });
            } else {
                try entries.append(.{ .prefix = "", .path = entry });
            }
        }
    }
    return entries.items;
}

/// Print a value in Nix's `nix eval` format (fully evaluated).
fn printValue(st: *eval.EvalState, v: *value.Value, w: *std.array_list.Managed(u8), depth: usize, raw: bool) !void {
    return printValueSeen(st, v, w, depth, raw, &.{});
}

fn printValueSeen(
    st: *eval.EvalState,
    v: *value.Value,
    w: *std.array_list.Managed(u8),
    depth: usize,
    raw: bool,
    seen: []const *const value.Attrs,
) !void {
    if (depth > 200) {
        try w.appendSlice("...");
        return;
    }
    try st.force(v);
    switch (v.*) {
        .int => |i| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{i})),
        .float => |f| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{f})),
        .bool_ => |b| try w.appendSlice(if (b) "true" else "false"),
        .null_ => try w.appendSlice("null"),
        .string => |s| {
            if (raw) {
                try w.appendSlice(s.s);
            } else {
                try w.append('"');
                for (s.s, 0..) |c, idx| {
                    switch (c) {
                        '"' => try w.appendSlice("\\\""),
                        '\\' => try w.appendSlice("\\\\"),
                        '\n' => try w.appendSlice("\\n"),
                        '\t' => try w.appendSlice("\\t"),
                        '\r' => try w.appendSlice("\\r"),
                        // escape '$' before '{' so the output round-trips
                        '$' => {
                            if (idx + 1 < s.s.len and s.s[idx + 1] == '{') {
                                try w.appendSlice("\\$");
                            } else {
                                try w.append(c);
                            }
                        },
                        else => try w.append(c),
                    }
                }
                try w.append('"');
            }
        },
        .path => |p| {
            if (raw) {
                try w.appendSlice(p.p);
            } else {
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "\"{s}\"", .{p.p}));
            }
        },
        .list => |l| {
            if (l.len == 0) {
                try w.appendSlice("[ ]");
                return;
            }
            try w.appendSlice("[ ");
            for (l, 0..) |e, i| {
                if (i > 0) try w.append(' ');
                try printValueSeen(st, e, w, depth + 1, raw, seen);
            }
            try w.appendSlice(" ]");
        },
        .attrs => |a| {
            for (seen) |s2| {
                if (s2 == a) {
                    try w.appendSlice("«repeated»");
                    return;
                }
            }
            // derivations print as «derivation <drvPath>» like real nix
            if (a.find("type")) |tv| {
                var t = tv.*;
                try st.force(&t);
                if (t == .string and std.mem.eql(u8, t.string.s, "derivation")) {
                    if (a.find("drvPath")) |dv| {
                        var d = dv.*;
                        try st.force(&d);
                        if (d == .string) {
                            try w.appendSlice("«derivation ");
                            try w.appendSlice(d.string.s);
                            try w.appendSlice("»");
                            return;
                        }
                    }
                }
            }
            if (a.items.len == 0) {
                try w.appendSlice("{ }");
                return;
            }
            try w.appendSlice("{ ");
            const new_seen = try st.alloc.alloc(*const value.Attrs, seen.len + 1);
            @memcpy(new_seen[0..seen.len], seen);
            new_seen[seen.len] = a;
            for (a.items, 0..) |it, i| {
                if (i > 0) try w.appendSlice("; ");
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{s} = ", .{it.name}));
                try printValueSeen(st, it.value, w, depth + 1, raw, new_seen);
            }
            try w.appendSlice("; }");
        },
        .lambda => try w.appendSlice("«lambda»"),
        .builtin => |b| {
            try w.appendSlice("«primop ");
            try w.appendSlice(b.name);
            try w.append('»');
        },
        .thunk => unreachable,
    }
}
