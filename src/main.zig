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
    zix.fsutil.io = init.io;

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
    var mode: enum { eval, parse, build, gc } = .eval;
    var expr_mode = false;
    var raw = false;
    var json = false;
    var sandbox = false;
    var read_only = false;
    var store_dir: []const u8 = init.environ_map.get("ZIX_STORE_DIR") orelse "/nix/store";
    var nix_path_extra = std.array_list.Managed([]const u8).init(a);
    var cli_args = std.array_list.Managed(ArgPair).init(a); // --arg/--argstr
    var attr_path: ?[]const u8 = null; // -A

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
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            // accepted; handled in the build section
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= argv.items.len) {
                std.debug.print("zix: missing argument for -I\n", .{});
                std.process.exit(1);
            }
            try nix_path_extra.append(argv.items[i]);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--sandbox") or std.mem.eql(u8, arg, "--no-sandbox")) {
            sandbox = std.mem.eql(u8, arg, "--sandbox");
        } else if (std.mem.eql(u8, arg, "--delete") and mode == .gc) {
            // handled by the gc section (needs to be seen before mode dispatch)
        } else if (std.mem.eql(u8, arg, "-A")) {
            i += 1;
            if (i >= argv.items.len) {
                std.debug.print("zix: missing argument for -A\n", .{});
                std.process.exit(1);
            }
            attr_path = argv.items[i];
        } else if (std.mem.eql(u8, arg, "--arg") or std.mem.eql(u8, arg, "--argstr")) {
            const is_str = std.mem.eql(u8, arg, "--argstr");
            i += 1;
            if (i + 1 >= argv.items.len) {
                std.debug.print("zix: missing arguments for {s}\n", .{arg});
                std.process.exit(1);
            }
            try cli_args.append(.{ .name = argv.items[i], .value = argv.items[i + 1], .is_str = is_str });
            i += 1;
        } else if (std.mem.eql(u8, arg, "parse")) {
            mode = .parse;
        } else if (std.mem.eql(u8, arg, "build")) {
            mode = .build;
        } else if (std.mem.eql(u8, arg, "gc")) {
            mode = .gc;
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

    if (mode == .gc) {
        var dry_run = true;
        for (argv.items[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--delete")) dry_run = false;
        }
        var live = std.StringHashMap(void).init(a);
        var it = st.store.db.iterator();
        while (it.next()) |e| {
            try live.put(e.key_ptr.*, {});
            for (e.value_ptr.refs) |r| try live.put(r, {});
        }
        var dir = std.Io.Dir.cwd().openDir(zix.fsutil.io, st.store.store_dir, .{ .iterate = true }) catch {
            std.debug.print("zix: cannot open store directory\n", .{});
            std.process.exit(1);
        };
        defer dir.close(zix.fsutil.io);
        var dit = dir.iterate();
        while (dit.next(zix.fsutil.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".drv")) continue;
            const full = try std.fs.path.join(a, &.{ st.store.store_dir, entry.name });
            const contents = zix.fsutil.readFileAlloc(a, full, 1 << 30) catch continue;
            const drv = zix.drv.parseDerivation(a, contents) catch continue;
            try live.put(full, {});
            for (drv.input_srcs) |s2| try live.put(s2, {});
            for (drv.input_drvs) |id| try live.put(id.path, {});
            for (drv.outputs) |o| if (o.path.len > 0) try live.put(o.path, {});
        }
        var freed: usize = 0;
        var dit2 = dir.iterate();
        while (dit2.next(zix.fsutil.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".drv")) continue;
            if (std.mem.eql(u8, entry.name, "zix-db.json") or std.mem.endsWith(u8, entry.name, ".tmp")) continue;
            const full = try std.fs.path.join(a, &.{ st.store.store_dir, entry.name });
            if (live.contains(full)) continue;
            if (dry_run) {
                std.debug.print("would delete: {s}\n", .{full});
            } else {
                dir.deleteFile(zix.fsutil.io, entry.name) catch continue;
            }
            freed += 1;
        }
        std.debug.print("zix: gc: {d} objects {s}\n", .{ freed, if (dry_run) "would delete" else "deleted" });
        return;
    }


    const target_str = target orelse {
        std.debug.print("zix: missing file or expression argument\n", .{});
        std.process.exit(1);
    };

    if (mode == .parse) {
        const contents = readFileOrExit(a, target_str);
        _ = st.parse(contents, target_str) catch |e| {
            if (st.err_msg.len > 0) {
                std.debug.print("zix: parse error: {s}\n", .{st.err_msg});
            } else {
                std.debug.print("zix: parse error: {s}\n", .{@errorName(e)});
            }
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
        json: bool,
        cli_args: []const ArgPair,
        apply_args: bool,
        attr_path: ?[]const u8,
    };
    // Evaluate AND print on a thread with a large stack: deep forcing of
    // the (lazy) result must not overflow the small main-thread stack.
    const run_eval = struct {
        fn f(ctx: RunCtx) void {
            var result = ctx.st.eval(ctx.parsed, ctx.st.base_env, 0) catch |e| exitEvalError(e, ctx.st);
            // --arg/--argstr: apply the args to the (function) expression.
            if (ctx.cli_args.len > 0 and ctx.apply_args) {
                const argset = makeCliArgset(ctx.st, ctx.cli_args) catch |e| exitEvalError(e, ctx.st);
                result = ctx.st.apply(result, argset, 0) catch |e| exitEvalError(e, ctx.st);
            }
            // -A attr-path: select the attribute path.
            if (ctx.attr_path) |ap| {
                var cur = result;
                var it = std.mem.tokenizeScalar(u8, ap, '.');
                while (it.next()) |name| {
                    ctx.st.force(&cur) catch |e| exitEvalError(e, ctx.st);
                    if (cur != .attrs) {
                        std.debug.print("zix: attribute '{s}' missing (cannot select from {s})\n", .{ name, eval.EvalState.showType(cur) });
                        std.process.exit(1);
                    }
                    const found = cur.attrs.find(name) orelse {
                        std.debug.print("zix: attribute '{s}' missing\n", .{name});
                        std.process.exit(1);
                    };
                    cur = found.*;
                }
                result = cur;
            }
            if (ctx.json) {
                zix.builtins.jsonWritePub(ctx.st, &result, ctx.output) catch |e| {
                    if (ctx.st.err_msg.len > 0) {
                        std.debug.print("zix: error printing value: {s}\n", .{ctx.st.err_msg});
                    } else {
                        std.debug.print("zix: error printing value: {s}\n", .{@errorName(e)});
                    }
                    std.process.exit(1);
                };
                return;
            }
            printValue(ctx.st, &result, ctx.output, 0, ctx.raw) catch |e| {
                if (ctx.st.err_msg.len > 0) {
                    std.debug.print("zix: error printing value: {s}\n", .{ctx.st.err_msg});
                    if (ctx.st.cur_pos.line > 0) {
                        std.debug.print("       at «{s}»:{d}:{d}\n", .{ ctx.st.cur_pos.file, ctx.st.cur_pos.line, ctx.st.cur_pos.col });
                    }
                    printTrace(ctx.st);
                } else {
                    std.debug.print("zix: error printing value: {s}\n", .{@errorName(e)});
                }
                std.process.exit(1);
            };
        }
    }.f;
    if (mode == .eval and expr_mode) {
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
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run_eval, .{ RunCtx{ .st = st, .parsed = parsed, .output = &output, .raw = raw, .json = json, .cli_args = cli_args.items, .apply_args = !expr_mode, .attr_path = attr_path } });
        t.join();
    } else if (mode == .eval) {
        const parsed = st.parseFile(target_str) catch |e| exitEvalError(e, st);
        st.cur_file = target_str;
        const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, run_eval, .{ RunCtx{ .st = st, .parsed = parsed, .output = &output, .raw = raw, .json = json, .cli_args = cli_args.items, .apply_args = !expr_mode, .attr_path = attr_path } });
        t.join();
    }

    if (mode == .build) {
        var dry_run = false;
        var verbose = false;
        for (argv.items[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) verbose = true;
        }
        const drv_path = try resolveDrvPath(st, target_str);
        const build_dir = std.fs.path.dirname(store_dir) orelse "/tmp";
        if (dry_run) {
            const plan = zix.build.planBuild(a, &st.store, drv_path) catch |e| exitEvalError(e, st);
            for (plan) |pstep| {
                std.debug.print("{s}\n", .{pstep.drv_path});
                for (pstep.drv.outputs) |o| std.debug.print("  -> {s}\n", .{o.path});
            }
        } else {
            const outs = zix.build.buildAll(a, &st.store, drv_path, build_dir, verbose, init.environ_map, sandbox) catch |e| exitEvalError(e, st);
            for (outs) |o| std.debug.print("{s}\n", .{o});
        }
        return;
    }

    try output.append('\n');
    writeStdout(output.items);
}

/// Resolve a `zix build` target to a .drv store path: either a path ending
/// in `.drv`, or a Nix expression/file whose value is a derivation.
fn resolveDrvPath(st: *eval.EvalState, target: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, target, ".drv") and zix.fsutil.pathExists(target)) return target;
    var result: value.Value = undefined;
    if (zix.fsutil.pathExists(target)) {
        result = st.importPath(target) catch |e| exitEvalError(e, st);
    } else {
        const cwd = fsutilRealpathCwd(st.alloc);
        const vfile = try std.fmt.allocPrint(st.alloc, "{s}/<command-line>", .{cwd});
        const parsed = st.parse(target, vfile) catch |e| exitEvalError(e, st);
        result = st.eval(parsed, st.base_env, 0) catch |e| exitEvalError(e, st);
    }
    try st.force(&result);
    if (result != .attrs) {
        std.debug.print("zix: error: 'zix build' target is not a derivation\n", .{});
        std.process.exit(1);
    }
    const dp = result.attrs.find("drvPath") orelse {
        std.debug.print("zix: error: 'zix build' target is not a derivation\n", .{});
        std.process.exit(1);
    };
    var dv = dp.*;
    try st.force(&dv);
    if (dv != .string) {
        std.debug.print("zix: error: 'zix build' target is not a derivation\n", .{});
        std.process.exit(1);
    }
    return dv.string.s;
}

const ArgPair = struct {
    name: []const u8,
    value: []const u8,
    is_str: bool,
};

fn makeCliArgset(st: *eval.EvalState, args: []const ArgPair) !*value.Value {
    const items = try st.alloc.alloc(value.Item, args.len);
    for (args, 0..) |p, i| {
        const v = try st.alloc.create(value.Value);
        if (p.is_str) {
            v.* = st.mkString(p.value, &.{});
        } else {
            // --arg: the value is parsed as a Nix expression.
            const parsed = try st.parse(p.value, "<command-line-arg>");
            v.* = try st.eval(parsed, st.base_env, 0);
        }
        items[i] = .{ .name = p.name, .value = v };
    }
    const attrs = try st.alloc.create(value.Attrs);
    attrs.* = .{ .items = items };
    const av = try st.alloc.create(value.Value);
    av.* = .{ .attrs = attrs };
    return av;
}

fn printTrace(st: *eval.EvalState) void {
    for (st.err_trace.items) |tp| std.debug.print("  «{s}»:{d}:{d}\n", .{ tp.file, tp.line, tp.col });
    var seen = std.StringHashMap(void).init(st.alloc);
    var i = st.err_trace.items.len;
    while (i > 0) {
        i -= 1;
        const p = st.err_trace.items[i];
        if (p.line == 0) continue;
        if (p.line == st.cur_pos.line and p.col == st.cur_pos.col and std.mem.eql(u8, p.file, st.cur_pos.file)) continue;
        const key = std.fmt.allocPrint(st.alloc, "{s}:{d}:{d}", .{ p.file, p.line, p.col }) catch continue;
        if (seen.contains(key)) continue;
        seen.put(key, {}) catch {};
        std.debug.print("       while evaluating at «{s}»:{d}:{d}\n", .{ p.file, p.line, p.col });
    }
}

fn exitEvalError(e: anyerror, st: *eval.EvalState) noreturn {
    if (st.err_msg.len > 0) {
        std.debug.print("zix: error: {s}\n", .{st.err_msg});
        if (st.cur_pos.line > 0) {
            std.debug.print("       at «{s}»:{d}:{d}\n", .{ st.cur_pos.file, st.cur_pos.line, st.cur_pos.col });
        }
        printTrace(st);
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
        .lambda => |l| {
            try w.appendSlice("«lambda @ «");
            if (std.mem.endsWith(u8, l.pos.file, "<command-line>")) {
                try w.appendSlice("string");
            } else {
                try w.appendSlice(l.pos.file);
            }
            try w.appendSlice(try std.fmt.allocPrint(st.alloc, "»:{d}:{d}»", .{ l.pos.line, l.pos.col }));
        },
        .builtin => |b| {
            try w.appendSlice("«primop ");
            try w.appendSlice(b.name);
            try w.append('»');
        },
        .thunk => unreachable,
    }
}
