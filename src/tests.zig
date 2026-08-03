//! Integration tests: evaluate Nix expressions and compare results —
//! including store paths verified against real Nix 2.34.7.

const std = @import("std");
const eval = @import("eval.zig");
const value = @import("value.zig");
const builtins = @import("builtins.zig");

fn newState(alloc: std.mem.Allocator) !*eval.EvalState {
    return eval.EvalState.init(alloc, "/nix/store", true, "/home/user");
}

fn evalStr(alloc: std.mem.Allocator, src: []const u8) !value.Value {
    const st = try newState(alloc);
    defer st.deinit();
    const parsed = try st.parse(src, "<test>");
    return st.eval(parsed, st.base_env, 0);
}

fn evalAndPrint(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    const st = try newState(alloc);
    defer st.deinit();
    const parsed = try st.parse(src, "<test>");
    var v = try st.eval(parsed, st.base_env, 0);
    var w = std.array_list.Managed(u8).init(alloc);
    try printTest(st, &v, &w, 0);
    return w.toOwnedSlice();
}

fn printTest(st: *eval.EvalState, v: *value.Value, w: *std.array_list.Managed(u8), depth: usize) !void {
    if (depth > 50) {
        try w.appendSlice("...");
        return;
    }
    try st.force(v);
    switch (v.*) {
        .int => |i| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{i})),
        .float => |f| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{f})),
        .bool_ => |b| try w.appendSlice(if (b) "true" else "false"),
        .null_ => try w.appendSlice("null"),
        .string => |s| try w.appendSlice(s.s),
        .path => |p| try w.appendSlice(p.p),
        .list => |l| {
            try w.append('[');
            for (l, 0..) |e, i| {
                if (i > 0) try w.append(' ');
                try printTest(st, e, w, depth + 1);
            }
            try w.append(']');
        },
        .attrs => |a| {
            try w.appendSlice("{ ");
            for (a.items, 0..) |it, i| {
                if (i > 0) try w.appendSlice("; ");
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{s} = ", .{it.name}));
                try printTest(st, it.value, w, depth + 1);
            }
            try w.appendSlice("; }");
        },
        .lambda => try w.appendSlice("<LAMBDA>"),
        .builtin => try w.appendSlice("<PRIMOP>"),
        .thunk => unreachable,
    }
}

fn expectEval(alloc: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try evalAndPrint(alloc, src);
    if (!std.mem.eql(u8, out, expected)) {
        std.debug.print("eval mismatch:\n  expr:     {s}\n  expected: {s}\n  got:      {s}\n", .{ src, expected, out });
        return error.TestExpectedEqual;
    }
}

test "eval: arithmetic and operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "1 + 2 * 3", "7");
    try expectEval(a, "(1 + 2) * 3", "9");
    try expectEval(a, "10 - 4 - 3", "3");
    try expectEval(a, "!true", "false");
    try expectEval(a, "true && false", "false");
    try expectEval(a, "true || false", "true");
    try expectEval(a, "false -> false", "true");
    try expectEval(a, "1 < 2", "true");
    try expectEval(a, "2 >= 2", "true");
    try expectEval(a, "1 == 1.0", "true");
    try expectEval(a, "[1 2] ++ [3]", "[1 2 3]");
    try expectEval(a, "{ a = 1; } // { b = 2; }", "{ a = 1; b = 2; }");
    try expectEval(a, "{ a = 1; } // { a = 2; }", "{ a = 2; }");
}

test "eval: strings and interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "\"a\" + \"b\"", "ab");
    try expectEval(a, "let x = 42; in \"value: ${x}\"", "value: 42");
    try expectEval(a, "''\n  hello\n  world\n''", "hello\nworld\n");
    try expectEval(a, "''  a''$b''", "a$b");
    try expectEval(a, "\"\\${not-interpolated}\"", "${not-interpolated}");
    try expectEval(a, "builtins.toString true", "1");
    try expectEval(a, "builtins.toString false", "");
}

test "eval: toString float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEval(arena.allocator(), "builtins.toString 2.5", "2.5");
}

test "eval: let/rec/with/functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "let x = 1; in x + 2", "3");
    try expectEval(a, "rec { a = 1; b = a + 1; }.b", "2");
    try expectEval(a, "let a = 1; b = a + 1; in b", "2");
    try expectEval(a, "with { a = 5; }; a", "5");
    try expectEval(a, "(x: x + 1) 41", "42");
    try expectEval(a, "({ a, b ? 10 }: a + b) { a = 1; }", "11");
    try expectEval(a, "({ a, ... }: a) { a = 1; b = 2; }", "1");
    try expectEval(a, "let f = { x, ... }@args: x + args.y; in f { x = 1; y = 2; }", "3");
    try expectEval(a, "if 1 < 2 then \"yes\" else \"no\"", "yes");
    try expectEval(a, "assert 1 == 1; 5", "5");
    try expectEval(a, "let xs = [1 2 3]; in builtins.foldl' (a: b: a + b) 0 xs", "6");
    try expectEval(a, "builtins.genList (x: x * x) 4", "[0 1 4 9]");
}

test "eval: builtins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "builtins.map (x: x * 2) [1 2 3]", "[2 4 6]");
    try expectEval(a, "builtins.filter (x: x > 1) [1 2 3]", "[2 3]");
    try expectEval(a, "builtins.attrNames { b = 1; a = 2; }", "[a b]");
    try expectEval(a, "builtins.attrValues { a = 1; b = 2; }", "[1 2]");
    try expectEval(a, "builtins.getAttr \"a\" { a = 1; }", "1");
    try expectEval(a, "builtins.hasAttr \"a\" { a = 1; }", "true");
    try expectEval(a, "builtins.removeAttrs { a = 1; b = 2; } [\"a\"]", "{ b = 2; }");
    try expectEval(a, "builtins.elemAt [10 20 30] 1", "20");
    try expectEval(a, "builtins.elem 2 [1 2 3]", "true");
    try expectEval(a, "builtins.typeOf [1]", "list");
    try expectEval(a, "builtins.typeOf { a = 1; }", "set");
    try expectEval(a, "builtins.isFunction (x: x)", "true");
    try expectEval(a, "builtins.substring 1 3 \"hello\"", "ell");
    try expectEval(a, "builtins.stringLength \"hello\"", "5");
    try expectEval(a, "builtins.toUpper \"abc\"", "ABC");
    try expectEval(a, "builtins.toLower \"ABC\"", "abc");
    try expectEval(a, "builtins.concatStringsSep \",\" [\"a\" \"b\" \"c\"]", "a,b,c");
    try expectEval(a, "builtins.replaceStrings [\"a\"] [\"b\"] \"aaa\"", "bbb");
    try expectEval(a, "builtins.splitVersion \"1.2.3pre\"", "[1 2 3 pre]");
    try expectEval(a, "builtins.parseDrvName \"foo-1.2.3\"", "{ name = foo; version = 1.2.3; }");
    try expectEval(a, "builtins.compareVersions \"2.3.1\" \"2.3a\"", "1");
    try expectEval(a, "builtins.hashString \"sha256\" \"hello\"", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    try expectEval(a, "builtins.toJSON { a = [1 2]; }", "{\"a\":[1,2]}");
    try expectEval(a, "builtins.fromJSON \"{\\\"a\\\":1}\"", "{ a = 1; }");
    try expectEval(a, "builtins.listToAttrs [{ name = \"a\"; value = 1; }]", "{ a = 1; }");
    try expectEval(a, "builtins.groupBy (x: if x > 0 then \"pos\" else \"neg\") [1 (-1) 2]", "{ neg = [-1]; pos = [1 2]; }");
    try expectEval(a, "builtins.genericClosure { startSet = [{ key = 1; }]; operator = x: []; }", "[{ key = 1; }]");
}

test "eval: store paths match real Nix 2.34.7" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // verified against `nix eval --expr '...' --raw` on Nix 2.34.7
    try expectEval(a, "builtins.toFile \"greeting\" \"hello world\"", "/nix/store/0vlnbn76kpspwrlbr01z13b61ml12y59-greeting");
    try expectEval(a, "(builtins.derivation { name = \"testdrv\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).drvPath", "/nix/store/k79611g7bg62d41fh6bvm7xpf1dl2x91-testdrv.drv");
    try expectEval(a, "(builtins.derivation { name = \"testdrv\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).outPath", "/nix/store/ak4bnbd0hy44016ypx2p50acsqdsms6p-testdrv");
    // fixed-output (flat)
    try expectEval(
        a,
        "(builtins.derivation { name = \"fetched\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputHash = \"0a3666a0710c08aa6d0de92ce72beeb5b93124cce1bf3701c9d6cdeb543cb73e\"; outputHashAlgo = \"sha256\"; outputHashMode = \"flat\"; }).outPath",
        "/nix/store/pn35a271shig8sp6d3aynp1lbilyb53p-fetched",
    );
    // fixed-output (recursive)
    try expectEval(
        a,
        "(builtins.derivation { name = \"fetched2\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputHash = \"0a3666a0710c08aa6d0de92ce72beeb5b93124cce1bf3701c9d6cdeb543cb73e\"; outputHashAlgo = \"sha256\"; outputHashMode = \"recursive\"; }).outPath",
        "/nix/store/1j8kwmir0bacybf0pq1ivdif3397zsrd-fetched2",
    );
    // derivation with an input reference (drv path depends on the ref)
    try expectEval(
        a,
        "let f = builtins.toFile \"greeting\" \"hello\"; in (builtins.derivation { name = \"uses-greeting\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; src = f; }).drvPath",
        "/nix/store/xvh7ac1gbl7c4qiznfnyw14kgjmsk705-uses-greeting.drv",
    );
    try expectEval(
        a,
        "let f = builtins.toFile \"greeting\" \"hello\"; in (builtins.derivation { name = \"uses-greeting\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; src = f; }).outPath",
        "/nix/store/ariwhq56zgfg4wd1qgkc6b1lh3qklmdh-uses-greeting",
    );
}

test "eval: laziness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `b` is never forced → `abort` never runs
    try expectEval(a, "let a = { b = builtins.abort \"nope\"; }; in 42", "42");
    // && short-circuits
    try expectEval(a, "false && builtins.abort \"nope\"", "false");
    // seq forces
    try expectEval(a, "builtins.seq 1 2", "2");
}
