//! Integration tests: evaluate Nix expressions and compare results —
//! including store paths verified against real Nix 2.34.7.

const std = @import("std");
const eval = @import("eval.zig");
const ast = @import("ast.zig");
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
            try w.appendSlice("[ ");
            for (l, 0..) |e, i| {
                if (i > 0) try w.append(' ');
                try printTest(st, e, w, depth + 1);
            }
            try w.appendSlice(" ]");
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

fn evalAndPrintNix(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    // Like evalAndPrint but uses Nix-style formatting (quoted strings).
    const st = try newState(alloc);
    defer st.deinit();
    const parsed = try st.parse(src, "<test>");
    var v = try st.eval(parsed, st.base_env, 0);
    var w = std.array_list.Managed(u8).init(alloc);
    try printTestNix(st, &v, &w, 0);
    return w.toOwnedSlice();
}

fn printTestNix(st: *eval.EvalState, v: *value.Value, w: *std.array_list.Managed(u8), depth: usize) !void {
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
        .string => |s| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "\"{s}\"", .{s.s})),
        .path => |p| try w.appendSlice(p.p),
        .list => |l| {
            try w.appendSlice("[ ");
            for (l, 0..) |e, i| {
                if (i > 0) try w.appendSlice(" ");
                try printTestNix(st, e, w, depth + 1);
            }
            if (l.len > 0) try w.appendSlice(" ");
            try w.appendSlice("]");
        },
        .attrs => |a| {
            try w.appendSlice("{ ");
            for (a.items, 0..) |it, i| {
                if (i > 0) try w.appendSlice("; ");
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{s} = ", .{it.name}));
                try printTestNix(st, it.value, w, depth + 1);
            }
            try w.appendSlice("; }");
        },
        .lambda => try w.appendSlice("«lambda»"),
        .builtin => |b| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "«primop {s}»", .{b.name})),
        .thunk => unreachable,
    }
}

fn expectEvalNix(alloc: std.mem.Allocator, src: []const u8, expected: []const u8) !void {
    const out = try evalAndPrintNix(alloc, src);
    if (!std.mem.eql(u8, out, expected)) {
        std.debug.print("eval mismatch (nix fmt):\n  expr:     {s}\n  expected: {s}\n  got:      {s}\n", .{ src, expected, out });
        return error.TestExpectedEqual;
    }
}

const EvalErrCtx = struct {
    st: *eval.EvalState,
    parsed: *const ast.Expr,
    ok: bool = false,
    err: eval.EvalError = error.InfiniteRecursion,
};
fn evalOnBigStack(st: *eval.EvalState, parsed: *const ast.Expr, ok: *bool, err: *eval.EvalError) void {
    var v = st.eval(parsed, st.base_env, 0) catch |e| {
        ok.* = false;
        err.* = e;
        return;
    };
    st.force(&v) catch |e| {
        ok.* = false;
        err.* = e;
        return;
    };
    ok.* = true;
}

fn expectEvalErr(alloc: std.mem.Allocator, src: []const u8, needle: []const u8) !void {
    const st = try newState(alloc);
    defer st.deinit();
    const parsed = try st.parse(src, "<test>");
    // Run on a large-stack thread: deep recursion must hit the call-depth
    // guard, not the (small) main-thread stack.
    var ok = false;
    var err: eval.EvalError = error.InfiniteRecursion;
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, evalOnBigStack, .{ st, parsed, &ok, &err });
    t.join();
    if (!ok) {
        if (std.mem.eql(u8, @errorName(err), needle)) return;
        // userError: check the message text
        if (std.mem.eql(u8, @errorName(err), "UserError") and std.mem.indexOf(u8, st.err_msg, needle) != null) return;
        std.debug.print("eval error mismatch:\n  expr: {s}\n  expected: {s}\n  got: {s}\n", .{ src, needle, @errorName(err) });
        return error.TestExpectedEqual;
    }
    std.debug.print("expected eval error '{s}' but succeeded: {s}\n", .{ needle, src });
    return error.TestExpectedEqual;
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
    try expectEval(a, "[1 2] ++ [3]", "[ 1 2 3 ]");
    try expectEval(a, "{ a = 1; } // { b = 2; }", "{ a = 1; b = 2; }");
    try expectEval(a, "{ a = 1; } // { a = 2; }", "{ a = 2; }");
}

test "eval: strings and interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "\"a\" + \"b\"", "ab");
    try expectEval(a, "let x = toString 42; in \"value: ${x}\"", "value: 42");
    try expectEval(a, "''\n  hello\n  world\n''", "hello\nworld\n");
    try expectEval(a, "''  a''$b''", "a$b");
    try expectEval(a, "\"\\${not-interpolated}\"", "${not-interpolated}");
    try expectEval(a, "builtins.toString true", "1");
    try expectEval(a, "builtins.toString false", "");
}

test "eval: toString float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectEval(arena.allocator(), "builtins.toString 2.5", "2.500000");
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
    try expectEval(a, "builtins.genList (x: x * x) 4", "[ 0 1 4 9 ]");
}

test "eval: builtins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEval(a, "builtins.map (x: x * 2) [1 2 3]", "[ 2 4 6 ]");
    try expectEval(a, "builtins.filter (x: x > 1) [1 2 3]", "[ 2 3 ]");
    try expectEval(a, "builtins.attrNames { b = 1; a = 2; }", "[ a b ]");
    try expectEval(a, "builtins.attrValues { a = 1; b = 2; }", "[ 1 2 ]");
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
    try expectEval(a, "builtins.splitVersion \"1.2.3pre\"", "[ 1 2 3 pre ]");
    try expectEval(a, "builtins.parseDrvName \"foo-1.2.3\"", "{ name = foo; version = 1.2.3; }");
    try expectEval(a, "builtins.compareVersions \"2.3.1\" \"2.3a\"", "1");
    try expectEval(a, "builtins.hashString \"sha256\" \"hello\"", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    try expectEval(a, "builtins.toJSON { a = [1 2]; }", "{\"a\":[1,2]}");
    try expectEval(a, "builtins.fromJSON \"{\\\"a\\\":1}\"", "{ a = 1; }");
    try expectEval(a, "builtins.listToAttrs [{ name = \"a\"; value = 1; }]", "{ a = 1; }");
    try expectEval(a, "builtins.groupBy (x: if x > 0 then \"pos\" else \"neg\") [1 (-1) 2]", "{ neg = [ -1 ]; pos = [ 1 2 ]; }");
    try expectEval(a, "builtins.genericClosure { startSet = [{ key = 1; }]; operator = x: []; }", "[ { key = 1; } ]");
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

test "eval: nixpkgs-compat regressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // trailing comma in formals
    try expectEval(a, "({ a, b, }: a + b) { a = 1; b = 2; }", "3");
    // @args visible in formals defaults (nixpkgs impure.nix pattern)
    try expectEval(a, "let f = { a ? b, ... }@b: b; in (f { x = 1; }).x", "1");
    // lazy mapAttrs (self-referential attrset must not cycle)
    try expectEval(a, "let final = { parsed = { abi = { assertions = [ ]; }; }; } // builtins.mapAttrs (n: v: v final.parsed) { isAndroid = x: x.isAndroid or false; }; in final.isAndroid", "false");
    // lazy map elements
    try expectEval(a, "let f = { a = 1; }; in builtins.map (x: x.a) [f]", "[ 1 ]");
    // builtins.split: separators become empty capture lists
    try expectEval(a, "builtins.split \"-\" \"x86_64-linux\"", "[ x86_64 [  ] linux ]");
    // builtins.mapAttrs
    try expectEval(a, "builtins.mapAttrs (n: v: v * 2) { a = 1; b = 2; }", "{ a = 2; b = 4; }");
    // builtins.mapAttrs'
    try expectEval(a, "builtins.mapAttrs' (n: v: { name = n + \"x\"; value = v; }) { a = 1; }", "{ ax = 1; }");
}

test "eval: positions (__curPos, unsafeGetAttrPos)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try newState(a);
    defer st.deinit();
    st.cur_file = "/test.nix";
    try expectEval(a, "builtins.unsafeGetAttrPos \"a\" { a = 1; }", "{ column = 33; file = <test>; line = 1; }");
    try expectEval(a, "builtins.unsafeGetAttrPos \"missing\" { a = 1; }", "null");
    try expectEval(a, "builtins.typeOf (builtins.unsafeGetAttrPos \"a\" { a = 1; })", "set");
}

test "eval: strict interpolation (Nix 2.3x)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Nix 2.34 does not coerce non-strings in interpolation
    const st = try newState(a);
    defer st.deinit();
    const parsed = try st.parse("\"${42}\"", "<test>");
    _ = st.eval(parsed, st.base_env, 0) catch {
        try std.testing.expect(true);
        return;
    };
    return error.TestExpectedEqual;
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

test "eval: deep-test regressions (float, split, recursion, toXML, hashes)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // leading-zero floats (Nix's FLOAT regex allows 0.x)
    try expectEval(a, "1 + 0.5", "1.5");
    try expectEval(a, "0.5 + 0.5", "1");
    try expectEval(a, "1 + 0.5e1", "6");
    // split: capture groups + trailing empty element (std::regex_iterator semantics)
    try expectEvalNix(a, "builtins.split \"(a)(b)\" \"ab\"", "[ \"\" [ \"a\" \"b\" ] \"\" ]");
    try expectEvalNix(a, "builtins.split \"-\" \"a-\"", "[ \"a\" [ ] \"\" ]");
    try expectEvalNix(a, "builtins.split \"\" \"ab\"", "[ \"\" [ ] \"a\" [ ] \"b\" [ ] \"\" ]");
    // self-referential thunks are infinite recursion, not hangs
    try expectEvalErr(a, "let x = x; in builtins.seq x 1", "InfiniteRecursion");
    try expectEvalErr(a, "rec { a = a; }.a", "InfiniteRecursion");
    try expectEvalErr(a, "let y = z; z = y; in y", "InfiniteRecursion");
    // deep recursion is a clean stack overflow (not a segfault)
    try expectEvalErr(a, "let f = x: f x; in f 1", "stack overflow");
    // listToAttrs keeps the first value for duplicate names
    try expectEval(a, "builtins.listToAttrs [ { name = \"a\"; value = 1; } { name = \"a\"; value = 2; } ]", "{ a = 1; }");
    // toXML (checked manually against Nix; string formatting with newlines is
    // verified via evalAndPrintNix + contains)
    {
        const out = try evalAndPrintNix(a, "builtins.toXML 42");
        if (std.mem.indexOf(u8, out, "<int value=\"42\" />") == null) {
            std.debug.print("toXML mismatch: {s}\n", .{out});
            return error.TestExpectedEqual;
        }
    }
    // hashString algorithms
    try expectEvalNix(a, "builtins.hashString \"md5\" \"abc\"", "\"900150983cd24fb0d6963f7d28e17f72\"");
    try expectEvalNix(a, "builtins.hashString \"sha512\" \"abc\"", "\"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f\"");
    // dirOf returns a path (printed bare)
    try expectEval(a, "builtins.dirOf /a/b/c.txt", "/a/b");
    // primop printing includes the closing guillemet
    try expectEvalNix(a, "builtins.attrValues", "«primop attrValues»");
}
