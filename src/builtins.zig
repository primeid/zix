//! Builtin functions (`builtins.*`) and constants, faithful to Nix 2.34's
//! `primops.cc`, including `derivationStrict` and the `derivation` wrapper.

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const eval = @import("eval.zig");
const store = @import("store.zig");
const drvmod = @import("drv.zig");
const nixhash = @import("nixhash.zig");
const fsutil = @import("fsutil.zig");

// `nix/fetchurl.nix` — the real Nix 2.34 corepkgs fetchurl builder.
pub const fetchurl_nix_src: []const u8 =
    "{\n  system ? \"\", # obsolete\n  url,\n  hash ? \"\", # an SRI hash\n\n  # Legacy hash specification\n  md5 ? \"\",\n  sha1 ? \"\",\n  sha256 ? \"\",\n  sha512 ? \"\",\n  outputHash ?\n    if hash != \"\" then\n      hash\n    else if sha512 != \"\" then\n      sha512\n    else if sha1 != \"\" then\n      sha1\n    else if md5 != \"\" then\n      md5\n    else\n      sha256,\n  outputHashAlgo ?\n    if hash != \"\" then\n      \"\"\n    else if sha512 != \"\" then\n      \"sha512\"\n    else if sha1 != \"\" then\n      \"sha1\"\n    else if md5 != \"\" then\n      \"md5\"\n    else\n      \"sha256\",\n\n  executable ? false,\n  unpack ? false,\n  name ? baseNameOf (toString url),\n  impure ? false,\n}:\n\nderivation (\n  {\n    builder = \"builtin:fetchurl\";\n\n    # New-style output content requirements.\n    outputHashMode = if unpack || executable then \"recursive\" else \"flat\";\n\n    inherit\n      name\n      url\n      executable\n      unpack\n      ;\n\n    system = \"builtin\";\n\n    # No need to double the amount of network traffic\n    preferLocalBuild = true;\n\n    # This attribute does nothing; it's here to avoid changing evaluation results.\n    impureEnvVars = [\n      \"http_proxy\"\n      \"https_proxy\"\n      \"ftp_proxy\"\n      \"all_proxy\"\n      \"no_proxy\"\n    ];\n\n    # To make \"nix-prefetch-url\" work.\n    urls = [ url ];\n  }\n  // (if impure then { __impure = true; } else { inherit outputHashAlgo outputHash; })\n)\n";
pub const Eval = eval.EvalState;
pub const Value = value.Value;
pub const EvalError = eval.EvalError;

pub const Init = struct {
    attrs: *value.Attrs,
    env: *value.Env,
};

// ---------------------------------------------------------------------------
// Builtin registration helpers
// ---------------------------------------------------------------------------

fn prim(st: *Eval, name: []const u8, arity: usize, f: anytype) !Value {
    const b = try st.alloc.create(value.Builtin);
    b.* = .{ .name = name, .arity = arity, .f = f };
    return .{ .builtin = b.* };
}

fn force(st: *Eval, v: *Value) EvalError!void {
    try st.force(v);
}

fn forceInt(st: *Eval, v: *Value, what: []const u8) EvalError!i64 {
    try st.force(v);
    return switch (v.*) {
        .int => |i| i,
        else => st.userError("expected an integer but found {s} {s}", .{ eval.EvalState.showType(v.*), what }),
    };
}

fn forceBool(st: *Eval, v: *Value, what: []const u8) EvalError!bool {
    try st.force(v);
    return switch (v.*) {
        .bool_ => |b| b,
        else => st.userError("expected a Boolean but found {s} {s}", .{ eval.EvalState.showType(v.*), what }),
    };
}

fn forceStringNoCtx(st: *Eval, v: *Value, what: []const u8) EvalError![]const u8 {
    try st.force(v);
    return switch (v.*) {
        .string => |s| s.s,
        else => st.userError("expected a string but found {s} {s}", .{ eval.EvalState.showType(v.*), what }),
    };
}

fn forceList(st: *Eval, v: *Value, what: []const u8) EvalError![]const *Value {
    try st.force(v);
    return switch (v.*) {
        .list => |l| l,
        else => st.userError("expected a list but found {s} {s}", .{ eval.EvalState.showType(v.*), what }),
    };
}

fn forceAttrs(st: *Eval, v: *Value, what: []const u8) EvalError!*value.Attrs {
    try st.force(v);
    return switch (v.*) {
        .attrs => |a| a,
        else => st.userError("expected a set but found {s} {s}", .{ eval.EvalState.showType(v.*), what }),
    };
}

fn forceStringWithCtx(st: *Eval, v: *Value, ctx: *std.array_list.Managed(value.CtxElem), copy: bool, what: []const u8) EvalError![]const u8 {
    return st.coerceToString(v, ctx, copy, false, what);
}

fn ctxStrings(st: *Eval, ctx: []const value.CtxElem) ![]const []const u8 {
    const out = try st.alloc.alloc([]const u8, ctx.len);
    for (ctx, 0..) |c, i| out[i] = c.path;
    return out;
}

// ---------------------------------------------------------------------------
// makeBuiltins
// ---------------------------------------------------------------------------

pub fn makeBuiltins(st: *Eval) !Init {
    var items = std.array_list.Managed(value.Item).init(st.alloc);

    const B = struct {
        fn add(list: *std.array_list.Managed(value.Item), st2: *Eval, name: []const u8, arity: usize, f: anytype) !void {
            const v = try st2.alloc.create(Value);
            if (arity == 0) {
                // Constant builtins (langVersion, storeDir, currentSystem, ...)
                // evaluate lazily: they may fail in pure mode, and evaluation
                // must happen at use, not at init.
                const b = try st2.alloc.create(value.Builtin);
                b.* = .{ .name = name, .arity = 0, .f = f };
                const t = try st2.alloc.create(value.Thunk);
                const ts = try st2.alloc.create(value.ThunkState);
                ts.* = .{};
                t.* = .{ .expr = undefined, .env = undefined, .state = ts, .pos = 0, .builtin = b.* };
                v.* = .{ .thunk = t };
            } else {
                const b = try st2.alloc.create(value.Builtin);
                b.* = .{ .name = name, .arity = arity, .f = f };
                v.* = .{ .builtin = b.* };
            }
            try list.append(.{ .name = name, .value = v });
        }
    };

    // --- constants that are both builtins and base-env vars ---
    const Const = struct {
        name: []const u8,
        val: Value,
    };
    var consts = std.array_list.Managed(Const).init(st.alloc);
    try consts.append(.{ .name = "true", .val = .{ .bool_ = true } });
    try consts.append(.{ .name = "false", .val = .{ .bool_ = false } });
    try consts.append(.{ .name = "null", .val = .null_ });
    for (consts.items) |c| {
        const v = try st.alloc.create(Value);
        v.* = c.val;
        try items.append(.{ .name = c.name, .value = v });
    }

    try B.add(&items, st, "abort", 1, primAbort);
    try B.add(&items, st, "throw", 1, primThrow);
    try B.add(&items, st, "trace", 2, primTrace);
    try B.add(&items, st, "seq", 2, primSeq);
    try B.add(&items, st, "deepSeq", 2, primDeepSeq);
    try B.add(&items, st, "add", 2, primAdd);
    try B.add(&items, st, "sub", 2, primSub);
    try B.add(&items, st, "mul", 2, primMul);
    try B.add(&items, st, "div", 2, primDiv);
    try B.add(&items, st, "lessThan", 2, primLessThan);
    try B.add(&items, st, "bitAnd", 2, primBitAnd);
    try B.add(&items, st, "bitOr", 2, primBitOr);
    try B.add(&items, st, "bitXor", 2, primBitXor);
    if (st.hasFeature("extra-builtins")) {
        try B.add(&items, st, "bitNot", 1, primBitNot);
    }
    try B.add(&items, st, "toString", 1, primToString);
    try B.add(&items, st, "toJSON", 1, primToJSON);
    try B.add(&items, st, "toXML", 1, primToXML);
    try B.add(&items, st, "fromJSON", 1, primFromJSON);
    try B.add(&items, st, "fromTOML", 1, primFromTOML);
    try B.add(&items, st, "map", 2, primMap);
    try B.add(&items, st, "mapAttrs", 2, primMapAttrs);
    if (st.hasFeature("extra-builtins")) {
        try B.add(&items, st, "mapAttrs'", 2, primMapAttrsPrime);
    }
    try B.add(&items, st, "toPath", 1, primToPath);
    try B.add(&items, st, "addDrvOutputDependencies", 1, primAddDrvOutputDependencies);
    try B.add(&items, st, "findFile", 2, primFindFile);
    try B.add(&items, st, "break", 2, primBreak);
    try B.add(&items, st, "fetchMercurial", 1, primFetchMercurial);
    try B.add(&items, st, "fetchTree", 1, primFetchTree);
    try B.add(&items, st, "getFlake", 1, primGetFlake);
    try B.add(&items, st, "parseFlakeRef", 1, primParseFlakeRef);
    try B.add(&items, st, "flakeRefToString", 1, primFlakeRefToString);
    try B.add(&items, st, "unsafeDiscardOutputDependency", 1, primUnsafeDiscardOutputDependency);
    try B.add(&items, st, "filter", 2, primFilter);
    try B.add(&items, st, "foldl'", 3, primFoldl);
    try B.add(&items, st, "genList", 2, primGenList);
    try B.add(&items, st, "length", 1, primLength);
    try B.add(&items, st, "head", 1, primHead);
    try B.add(&items, st, "tail", 1, primTail);
    try B.add(&items, st, "elemAt", 2, primElemAt);
    try B.add(&items, st, "elem", 2, primElem);
    try B.add(&items, st, "concatLists", 1, primConcatLists);
    try B.add(&items, st, "concatMap", 2, primConcatMap);
    try B.add(&items, st, "all", 2, primAll);
    try B.add(&items, st, "any", 2, primAny);
    if (st.hasFeature("extra-builtins")) {
        try B.add(&items, st, "take", 2, primTake);
        try B.add(&items, st, "drop", 2, primDrop);
        try B.add(&items, st, "reverseList", 1, primReverseList);
    }
    try B.add(&items, st, "sort", 2, primSort);
    try B.add(&items, st, "partition", 2, primPartition);
    try B.add(&items, st, "groupBy", 2, primGroupBy);
    try B.add(&items, st, "attrNames", 1, primAttrNames);
    try B.add(&items, st, "attrValues", 1, primAttrValues);
    try B.add(&items, st, "hasAttr", 2, primHasAttr);
    try B.add(&items, st, "getAttr", 2, primGetAttr);
    try B.add(&items, st, "removeAttrs", 2, primRemoveAttrs);
    try B.add(&items, st, "listToAttrs", 1, primListToAttrs);
    try B.add(&items, st, "catAttrs", 2, primCatAttrs);
    try B.add(&items, st, "intersectAttrs", 2, primIntersectAttrs);
    try B.add(&items, st, "zipAttrsWith", 2, primZipAttrsWith);
    try B.add(&items, st, "functionArgs", 1, primFunctionArgs);
    try B.add(&items, st, "isAttrs", 1, primIs(.attrs, "isAttrs"));
    try B.add(&items, st, "isList", 1, primIs(.list, "isList"));
    try B.add(&items, st, "isString", 1, primIs(.string, "isString"));
    try B.add(&items, st, "isInt", 1, primIs(.int, "isInt"));
    try B.add(&items, st, "isFloat", 1, primIs(.float, "isFloat"));
    try B.add(&items, st, "isBool", 1, primIs(.bool_, "isBool"));
    try B.add(&items, st, "isNull", 1, primIs(.null_, "isNull"));
    try B.add(&items, st, "isFunction", 1, primIsFunction);
    try B.add(&items, st, "isPath", 1, primIs(.path, "isPath"));
    try B.add(&items, st, "typeOf", 1, primTypeOf);
    try B.add(&items, st, "stringLength", 1, primStringLength);
    try B.add(&items, st, "substring", 3, primSubstring);
    if (st.hasFeature("extra-builtins")) {
        try B.add(&items, st, "toUpper", 1, primToUpper);
        try B.add(&items, st, "toLower", 1, primToLower);
    }
    try B.add(&items, st, "replaceStrings", 3, primReplaceStrings);
    try B.add(&items, st, "concatStringsSep", 2, primConcatStringsSep);
    try B.add(&items, st, "split", 2, primSplit);
    try B.add(&items, st, "match", 2, primMatch);
    try B.add(&items, st, "compareVersions", 2, primCompareVersions);
    try B.add(&items, st, "splitVersion", 1, primSplitVersion);
    try B.add(&items, st, "parseDrvName", 1, primParseDrvName);
    try B.add(&items, st, "baseNameOf", 1, primBaseNameOf);
    try B.add(&items, st, "dirOf", 1, primDirOf);
    try B.add(&items, st, "readFile", 1, primReadFile);
    try B.add(&items, st, "readDir", 1, primReadDir);
    try B.add(&items, st, "toFile", 2, primToFile);
    try B.add(&items, st, "path", 1, primPath);
    try B.add(&items, st, "pathExists", 1, primPathExists);
    try B.add(&items, st, "hashString", 2, primHashString);
    try B.add(&items, st, "hashFile", 2, primHashFile);
    try B.add(&items, st, "storePath", 1, primStorePath);
    try B.add(&items, st, "getEnv", 1, primGetEnv);
    try B.add(&items, st, "unsafeGetAttrPos", 2, primUnsafeGetAttrPos);
    try B.add(&items, st, "derivationStrict", 1, primDerivationStrict);
    try B.add(&items, st, "fetchurl", 1, primFetchurl);
    try B.add(&items, st, "fetchTarball", 1, primFetchTarball);
    try B.add(&items, st, "fetchzip", 1, primFetchTarball);
    try B.add(&items, st, "fetchGit", 1, primFetchGit);
    try B.add(&items, st, "placeholder", 1, primPlaceholder);
    try B.add(&items, st, "import", 1, primImport);
    try B.add(&items, st, "scopedImport", 2, primScopedImport);
    try B.add(&items, st, "tryEval", 1, primTryEval);
    try B.add(&items, st, "genericClosure", 1, primGenericClosure);
    try B.add(&items, st, "unsafeDiscardStringContext", 1, primUnsafeDiscardStringContext);
    try B.add(&items, st, "addErrorContext", 2, primSecond);
    try B.add(&items, st, "currentSystem", 0, primCurrentSystem);
    try B.add(&items, st, "currentTime", 0, primCurrentTime);
    try B.add(&items, st, "nixVersion", 0, primNixVersion);
    try B.add(&items, st, "langVersion", 0, primLangVersion);
    try B.add(&items, st, "storeDir", 0, primStoreDir);
    try B.add(&items, st, "nixPath", 0, primNixPath);
    try B.add(&items, st, "getContext", 1, primGetContext);
    try B.add(&items, st, "hasContext", 1, primHasContext);
    try B.add(&items, st, "ceil", 1, primCeil);
    try B.add(&items, st, "floor", 1, primFloor);
    try B.add(&items, st, "readFileType", 1, primReadFileType);
    try B.add(&items, st, "warn", 2, primWarn);
    try B.add(&items, st, "traceVerbose", 2, primTraceVerbose);
    try B.add(&items, st, "convertHash", 1, primConvertHash);
    try B.add(&items, st, "filterSource", 2, primFilterSource);
    try B.add(&items, st, "appendContext", 2, primAppendContext);

    const builtins_attrs = try st.alloc.create(value.Attrs);
    std.mem.sort(value.Item, items.items, {}, struct {
        fn lt(_: void, a: value.Item, b: value.Item) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    builtins_attrs.* = .{ .items = items.items };
    // `derivation` wrapper — embedded from Nix 2.34 corepkgs/derivation.nix
    {
        const src = derivationWrapperSrc;
        const parsed = try st.parse(src, "<zix-corepkgs>/derivation.nix");
        var v = try st.eval(parsed, st.base_env, 0);
        _ = &v;
    }

    // base env: all builtins as bare names + constants + `builtins` attrset
    var vars = std.array_list.Managed(value.Var).init(st.alloc);
    const builtins_val = try st.alloc.create(Value);
    builtins_val.* = .{ .attrs = builtins_attrs };
    try vars.append(.{ .name = "builtins", .value = builtins_val });
    for (items.items) |it| {
        try vars.append(.{ .name = it.name, .value = it.value });
    }
    for (consts.items) |c| {
        const v = try st.alloc.create(Value);
        v.* = c.val;
        try vars.append(.{ .name = c.name, .value = v });
    }
    const env = try st.alloc.create(value.Env);
    env.* = .{ .parent = null, .vars = vars.items };

    // eval the derivation wrapper with the base env (needs `builtins`)
    st.base_env = env;
    const parsed = try st.parse(derivationWrapperSrc, "<zix-corepkgs>/derivation.nix");
    const wrapper = try st.eval(parsed, env, 0);
    const wv = try st.alloc.create(Value);
    wv.* = wrapper;
    // bind `derivation` in builtins, in the base env, and in constants
    var items2 = std.array_list.Managed(value.Item).init(st.alloc);
    try items2.appendSlice(builtins_attrs.items);
    try items2.append(.{ .name = "derivation", .value = wv });
    std.mem.sort(value.Item, items2.items, {}, struct {
        fn lt(_: void, a: value.Item, b: value.Item) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    builtins_attrs.items = items2.items;
    var vars2 = std.array_list.Managed(value.Var).init(st.alloc);
    try vars2.appendSlice(env.vars);
    try vars2.append(.{ .name = "derivation", .value = wv });
    env.vars = vars2.items;

    return .{ .attrs = builtins_attrs, .env = env };
}

const derivationWrapperSrc =
    \\drvAttrs@{ outputs ? [ "out" ], ... }:
    \\let
    \\  strict = derivationStrict drvAttrs;
    \\  commonAttrs =
    \\    drvAttrs
    \\    // (builtins.listToAttrs outputsList)
    \\    // {
    \\      all = map (x: x.value) outputsList;
    \\      inherit drvAttrs;
    \\    };
    \\  outputToAttrListElement = outputName: {
    \\    name = outputName;
    \\    value = commonAttrs // {
    \\      outPath = builtins.getAttr outputName strict;
    \\      drvPath = strict.drvPath;
    \\      type = "derivation";
    \\      inherit outputName;
    \\    };
    \\  };
    \\  outputsList = map outputToAttrListElement outputs;
    \\in
    \\(builtins.head outputsList).value
;

// ---------------------------------------------------------------------------
// Basic builtins
// ---------------------------------------------------------------------------

fn primAbort(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const msg = try forceStringNoCtx(st, args[0], "while evaluating the argument to builtins.abort");
    return st.userError("evaluation aborted with the following error message: '{s}'", .{msg});
}

fn primThrow(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const msg = try forceStringNoCtx(st, args[0], "while evaluating the argument to builtins.throw");
    return st.userErrorKind(.thrown, "throw: {s}", .{msg});
}

fn primTrace(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const msg = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.trace");
    std.debug.print("trace: {s}\n", .{msg});
    return args[1].*;
}

fn primSecond(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = st;
    _ = pos;

    return args[1].*;
}

fn primSeq(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    return args[1].*;
}

fn primDeepSeq(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try deepForce(st, &v);
    return args[1].*;
}

fn deepForce(st: *Eval, v: *Value) EvalError!void {
    try st.force(v);
    switch (v.*) {
        .list => |l| for (l) |e| try deepForce(st, e),
        .attrs => |a| for (a.items) |it| try deepForce(st, it.value),
        else => {},
    }
}

fn arith(st: *Eval, args: []const *Value, comptime op: enum { add, sub, mul, div }, pos: usize) EvalError!Value {
    _ = pos;
    var av = args[0].*;
    var bv = args[1].*;
    try st.force(&av);
    try st.force(&bv);
    const a_int = av == .int;
    const b_int = bv == .int;
    if (a_int and b_int) {
        const a = av.int;
        const b = bv.int;
        const r = switch (op) {
            .add => std.math.add(i64, a, b) catch return st.userError("integer overflow in adding {d} + {d}", .{ a, b }),
            .sub => std.math.sub(i64, a, b) catch return st.userError("integer overflow in subtracting {d} - {d}", .{ a, b }),
            .mul => std.math.mul(i64, a, b) catch return st.userError("integer overflow in multiplying {d} * {d}", .{ a, b }),
            .div => blk: {
                if (b == 0) return st.userError("division by zero", .{});
                break :blk std.math.divTrunc(i64, a, b) catch return st.userError("integer overflow in dividing {d} / {d}", .{ a, b });
            },
        };
        return .{ .int = r };
    }
    const af: f64 = if (a_int) @floatFromInt(av.int) else if (av == .float) av.float else return st.userError("cannot use {s} in arithmetic", .{eval.EvalState.showType(av)});
    const bf: f64 = if (b_int) @floatFromInt(bv.int) else if (bv == .float) bv.float else return st.userError("cannot use {s} in arithmetic", .{eval.EvalState.showType(bv)});
    return .{ .float = switch (op) {
        .add => af + bf,
        .sub => af - bf,
        .mul => af * bf,
        .div => blk: {
            if (bf == 0) return st.userError("division by zero", .{});
            break :blk af / bf;
        },
    } };
}

fn primAdd(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    return arith(st, args, .add, pos);
}
fn primSub(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    return arith(st, args, .sub, pos);
}
fn primMul(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    return arith(st, args, .mul, pos);
}
fn primDiv(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    return arith(st, args, .div, pos);
}

fn primLessThan(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var a = args[0].*;
    var b = args[1].*;
    try st.force(&a);
    try st.force(&b);
    const r = switch (a) {
        .int => |i| switch (b) {
            .int => |j| i < j,
            .float => |f| @as(f64, @floatFromInt(i)) < f,
            else => return st.userError("cannot compare {s} with {s}", .{ eval.EvalState.showType(a), eval.EvalState.showType(b) }),
        },
        .float => |f| switch (b) {
            .int => |j| f < @as(f64, @floatFromInt(j)),
            .float => |g| f < g,
            else => return st.userError("cannot compare {s} with {s}", .{ eval.EvalState.showType(a), eval.EvalState.showType(b) }),
        },
        .string => |s| switch (b) {
            .string => |t| std.mem.order(u8, s.s, t.s) == .lt,
            .path => |p| std.mem.order(u8, s.s, p.p) == .lt,
            else => return st.userError("cannot compare {s} with {s}", .{ eval.EvalState.showType(a), eval.EvalState.showType(b) }),
        },
        .path => |p| switch (b) {
            .path => |q| std.mem.order(u8, p.p, q.p) == .lt,
            .string => |s| std.mem.order(u8, p.p, s.s) == .lt,
            else => return st.userError("cannot compare {s} with {s}", .{ eval.EvalState.showType(a), eval.EvalState.showType(b) }),
        },
        else => return st.userError("cannot compare {s} with {s}", .{ eval.EvalState.showType(a), eval.EvalState.showType(b) }),
    };
    return .{ .bool_ = r };
}

fn primBitAnd(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    return .{ .int = (try forceInt(st, args[0], "")) & (try forceInt(st, args[1], "")) };
}
fn primBitOr(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    return .{ .int = (try forceInt(st, args[0], "")) | (try forceInt(st, args[1], "")) };
}
fn primBitXor(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    return .{ .int = (try forceInt(st, args[0], "")) ^ (try forceInt(st, args[1], "")) };
}
fn primBitNot(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    return .{ .int = ~(try forceInt(st, args[0], "")) };
}

fn primToString(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const s = try st.coerceToString(&v, &ctx, false, true, "while evaluating the argument to builtins.toString");
    return st.mkString(s, ctx.items);
}

fn primIs(comptime tag: std.meta.Tag(Value), comptime name: []const u8) *const fn (st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    return struct {
        fn f(st2: *Eval, args2: []const *Value, pos2: usize) EvalError!Value {
            _ = name;
            _ = pos2;
            var v = args2[0].*;
            try st2.force(&v);
            return .{ .bool_ = std.meta.activeTag(v) == tag };
        }
    }.f;
}

fn primIsFunction(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    return .{ .bool_ = v == .lambda or v == .builtin };
}

fn primTypeOf(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const t: []const u8 = switch (v) {
        .int => "int",
        .float => "float",
        .bool_ => "bool",
        .null_ => "null",
        .string => "string",
        .path => "path",
        .list => "list",
        .attrs => "set",
        .lambda, .builtin => "lambda",
        else => "unknown",
    };
    return st.mkString(t, &.{});
}

// ---------------------------------------------------------------------------
// List builtins
// ---------------------------------------------------------------------------

fn primMapAttrs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    const fun = args[0].*;
    const a = try forceAttrs(st, args[1], "while evaluating the second argument to builtins.mapAttrs");
    const items = try st.alloc.alloc(value.Item, a.items.len);
    for (a.items, 0..) |it, i| {
        const name_v = try st.alloc.create(Value);
        name_v.* = st.mkString(it.name, &.{});
        // Lazy value thunks (like Nix): the application is forced on access.
        const v = try st.alloc.create(Value);
        v.* = try st.mkLazyApply(fun, &.{ name_v, it.value }, pos);
        items[i] = .{ .name = it.name, .value = v };
    }
    return st.mkAttrs(items);
}

fn primMapAttrsPrime(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const fun = args[0].*;
    const a = try forceAttrs(st, args[1], "while evaluating the second argument to builtins.mapAttrs'");
    const items = try st.alloc.alloc(value.Item, a.items.len);
    for (a.items, 0..) |it, i| {
        const name_v = try st.alloc.create(Value);
        name_v.* = st.mkString(it.name, &.{});
        var r = try st.apply(fun, name_v, 0);
        r = try st.apply(r, it.value, 0);
        var rv = r;
        try st.force(&rv);
        if (rv != .attrs) return st.userError("builtins.mapAttrs' expected a {{ name, value }} pair", .{});
        const nv = rv.attrs.find("name") orelse return st.userError("builtins.mapAttrs' result missing 'name'", .{});
        var nv2 = nv.*;
        const new_name = try forceStringNoCtx(st, &nv2, "while evaluating the 'name' of a mapAttrs' result");
        const vv = rv.attrs.find("value") orelse return st.userError("builtins.mapAttrs' result missing 'value'", .{});
        items[i] = .{ .name = new_name, .value = vv };
    }
    return st.mkAttrs(items);
}

fn primFindFile(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var paths_v = args[0].*;
    try st.force(&paths_v);
    var name_v = args[1].*;
    try st.force(&name_v);
    const name = try forceStringNoCtx(st, &name_v, "while evaluating the second argument to builtins.findFile");
    // The first argument is a list of search-path entries (like nixPath).
    if (paths_v == .list) {
        for (paths_v.list) |pv| {
            var p = pv.*;
            try st.force(&p);
            if (p != .attrs) continue;
            const path_attr = p.attrs.find("path") orelse continue;
            var pathv = path_attr.*;
            try st.force(&pathv);
            const p2 = try forceStringNoCtx(st, &pathv, "while evaluating the 'path' attribute");
            const prefix_v = p.attrs.find("prefix");
            const use: ?[]const u8 = if (prefix_v) |pv2| blk: {
                var pfv = pv2.*;
                try st.force(&pfv);
                const prefix = try forceStringNoCtx(st, &pfv, "while evaluating the 'prefix' attribute");
                if (std.mem.eql(u8, prefix, name)) {
                    break :blk p2;
                }
                if (!(std.mem.startsWith(u8, name, prefix) and name.len > prefix.len and name[prefix.len] == '/')) {
                    continue;
                }
                const rest = name[prefix.len + 1 ..];
                break :blk try std.fs.path.join(st.alloc, &.{ p2, rest });
            } else p2;
            _ = &use;
            if (use) |u| {
                if (!fsutil.pathExists(u)) {
                    continue;
                }
                const ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
                return st.mkString(try st.alloc.dupe(u8, u), ctx.items);
            }
        }
    } else {
        return st.userError("'findFile' called on {s}, expected a list", .{eval.EvalState.showType(paths_v)});
    }
    return st.userError("unable to find '{s}'", .{name});
}

fn primBreak(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    // Nix 2.34's deprecated `break` treats the message as a callable and
    // fails with "attempt to call something which is not a function".
    const msg = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.break");
    return st.userError("attempt to call something which is not a function but a string: {s}", .{msg});
}

fn primFetchMercurial(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.fetchMercurial");
    const url_v = a.find("url") orelse return st.userError("attribute 'url' missing in builtins.fetchMercurial", .{});
    var uv = url_v.*;
    try st.force(&uv);
    const url = try forceStringNoCtx(st, &uv, "while evaluating the 'url' attribute of builtins.fetchMercurial");
    const rev_v = a.find("rev");
    _ = rev_v;
    // Like Nix: invoke the `hg` binary; the exact error when it is missing
    // matches Nix's "executing "hg": No such file or directory".
    var argv = std.array_list.Managed([]const u8).init(st.alloc);
    try argv.append("hg");
    try argv.append("clone");
    try argv.append(url);
    const tmp = try std.fmt.allocPrint(st.alloc, "/tmp/zix-hg-{s}", .{std.fs.path.basename(url)});
    try argv.append(tmp);
    var child = std.process.spawn(fsutil.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        // Match Nix's exec error text for a missing binary.
        const why = if (e == error.FileNotFound) "No such file or directory" else @errorName(e);
        return st.userError("executing \"hg\": {s}", .{why});
    };
    const term = child.wait(fsutil.io) catch return error.IoError;
    switch (term) {
        .exited => |code| if (code != 0) {
            return st.userError("unable to fetch Mercurial repository '{s}'", .{url});
        },
        else => return st.userError("unable to fetch Mercurial repository '{s}'", .{url}),
    }
    _ = rev_v;
    const sp = store.addPathToStore(&st.store, std.fs.path.basename(url), tmp) catch |e| {
        return st.userError("cannot copy to store: {s}", .{@errorName(e)});
    };
    return st.mkString(try st.alloc.dupe(u8, sp), &.{});
}

fn primFetchTree(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    // Minimal fetchTree: github / git types via git, tarball via curl.
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.fetchTree");
    const type_v = a.find("type") orelse return st.userError("attribute 'type' missing in builtins.fetchTree", .{});
    var tv = type_v.*;
    try st.force(&tv);
    const typ = try forceStringNoCtx(st, &tv, "while evaluating the 'type' attribute");
    if (std.mem.eql(u8, typ, "github")) {
        const owner_v = a.find("owner") orelse return st.userError("attribute 'owner' missing", .{});
        const repo_v = a.find("repo") orelse return st.userError("attribute 'repo' missing", .{});
        var ov = owner_v.*; try st.force(&ov);
        var rv = repo_v.*; try st.force(&rv);
        const owner = try forceStringNoCtx(st, &ov, "");
        const repo = try forceStringNoCtx(st, &rv, "");
        const url = try std.fmt.allocPrint(st.alloc, "https://github.com/{s}/{s}.git", .{ owner, repo });
        return st.fetchGitAttrs(url, null, null);
    }
    return st.userError("unsupported fetchTree type '{s}'", .{typ});
}

fn primGetFlake(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const ref = try forceStringNoCtx(st, &v, "while evaluating the argument to builtins.getFlake");
    if (std.mem.startsWith(u8, ref, "github:")) {
        const rest = ref["github:".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return st.userError("invalid flake reference '{s}'", .{ref});
        const owner = rest[0..slash];
        var repo = rest[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, repo, '/')) |s2| repo = repo[0..s2];
        const url = try std.fmt.allocPrint(st.alloc, "https://github.com/{s}/{s}.git", .{ owner, repo });
        const tree = try st.fetchGitAttrs(url, null, null);
        // Return a minimal flake attrset with the source tree.
        const items = try st.alloc.alloc(value.Item, 2);
        const pv = try st.alloc.create(Value);
        pv.* = tree;
        items[0] = .{ .name = "outPath", .value = pv };
        const tv2 = try st.alloc.create(Value);
        tv2.* = st.mkString("flake", &.{});
        items[1] = .{ .name = "type", .value = tv2 };
        return st.mkAttrs(items);
    }
    return st.userError("unsupported flake reference '{s}'", .{ref});
}

fn primParseFlakeRef(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const s = try forceStringNoCtx(st, &v, "while evaluating the argument to builtins.parseFlakeRef");
    // Minimal flake-ref parser: type:owner/repo or type:owner/repo/rev
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse
        return st.userError("invalid flake reference '{s}'", .{s});
    const typ = s[0..colon];
    const rest = s[colon + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
        return st.userError("invalid flake reference '{s}'", .{s});
    const owner = rest[0..slash];
    const rest2 = rest[slash + 1 ..];
    var repo = rest2;
    var rev: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest2, '/')) |s2| {
        repo = rest2[0..s2];
        rev = rest2[s2 + 1 ..];
    }
    const items = try st.alloc.alloc(value.Item, 3 + @as(usize, @intFromBool(rev.len > 0)));
    const tv = try st.alloc.create(Value); tv.* = st.mkString(typ, &.{});
    const ov = try st.alloc.create(Value); ov.* = st.mkString(owner, &.{});
    const rv = try st.alloc.create(Value); rv.* = st.mkString(repo, &.{});
    items[0] = .{ .name = "type", .value = tv };
    items[1] = .{ .name = "owner", .value = ov };
    items[2] = .{ .name = "repo", .value = rv };
    if (rev.len > 0) {
        const revv = try st.alloc.create(Value); revv.* = st.mkString(rev, &.{});
        items[3] = .{ .name = "ref", .value = revv };
    }
    return st.mkAttrs(items);
}

fn primFlakeRefToString(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var av = args[0].*;
    try st.force(&av);
    if (av != .attrs) return st.userError("'flakeRefToString' called on {s}, expected a set", .{eval.EvalState.showType(av)});
    const type_v = av.attrs.find("type") orelse return st.userError("input attribute 'type' is missing", .{});
    var tv = type_v.*;
    try st.force(&tv);
    const typ = try forceStringNoCtx(st, &tv, "while evaluating the 'type' attribute");
    if (std.mem.eql(u8, typ, "github")) {
        const owner_v = av.attrs.find("owner") orelse return st.userError("input attribute 'owner' is missing", .{});
        const repo_v = av.attrs.find("repo") orelse return st.userError("input attribute 'repo' is missing", .{});
        var ov = owner_v.*; try st.force(&ov);
        var rv = repo_v.*; try st.force(&rv);
        const owner = try forceStringNoCtx(st, &ov, "");
        const repo = try forceStringNoCtx(st, &rv, "");
        var out = std.array_list.Managed(u8).init(st.alloc);
        try out.appendSlice("github:");
        try out.appendSlice(owner);
        try out.append('/');
        try out.appendSlice(repo);
        return st.mkString(try st.alloc.dupe(u8, out.items), &.{});
    }
    return st.userError("unsupported flake reference type '{s}'", .{typ});
}

fn primUnsafeDiscardOutputDependency(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    if (v == .string) return st.mkString(try st.alloc.dupe(u8, v.string.s), &.{});
    return v;
}

fn primAddDrvOutputDependencies(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const s = try forceStringWithCtx(st, args[0], &ctx, false, "while evaluating the argument to builtins.addDrvOutputDependencies");
    // Nix requires exactly one drv-output element in the string context.
    if (ctx.items.len != 1 or ctx.items[0].kind != .drv_out) {
        return st.userError("context of string '{s}' must have exactly one element", .{s});
    }
    return st.mkString(try st.alloc.dupe(u8, s), ctx.items);
}

fn primToPath(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const s = try forceStringNoCtx(st, args[0], "while evaluating the argument to builtins.toPath");
    return .{ .path = .{ .p = s } };
}

fn primMap(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "while evaluating the second argument to builtins.map");
    const out = try st.alloc.alloc(*Value, list.len);
    for (list, 0..) |elem, i| {
        out[i] = try st.alloc.create(Value);
        out[i].* = try st.apply(fun, elem, pos);
    }
    return .{ .list = out };
}

fn primFilter(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    var out = std.array_list.Managed(*Value).init(st.alloc);
    for (list) |elem| {
        var r = try st.apply(fun, elem, pos);
        if (try forceBool(st, &r, "")) try out.append(elem);
    }
    return .{ .list = out.items };
}

fn primFoldl(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    // Every step binds the accumulator to a *fresh* heap slot: the fold
    // lambda (and any thunks it creates) captures the accumulator pointer, so
    // a shared/mutated slot would make those thunks see later values
    // (self-reference cycles like
    // `foldl' (res: opt: res // { options = [1] ++ res.options; }) ...`).
    const list = try forceList(st, args[2], "");
    var acc = try st.alloc.create(Value);
    acc.* = args[1].*;
    for (list) |elem| {
        var r = try st.apply(fun, acc, pos);
        r = try st.apply(r, elem, pos);
        const fresh = try st.alloc.create(Value);
        fresh.* = r;
        acc = fresh;
    }
    return acc.*;
}

fn primGenList(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const n = try forceInt(st, args[1], "");
    if (n < 0) return st.userError("cannot create list of size {d}", .{n});
    const out = try st.alloc.alloc(*Value, @intCast(n));
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const idx = try st.alloc.create(Value);
        idx.* = .{ .int = @intCast(i) };
        out[i] = try st.alloc.create(Value);
        out[i].* = try st.apply(fun, idx, pos);
    }
    return .{ .list = out };
}

fn primLength(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    return .{ .int = @intCast(list.len) };
}

fn primHead(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    if (list.len == 0) return st.userError("'head' called on an empty list", .{});
    return list[0].*;
}

fn primTail(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    if (list.len == 0) return st.userError("'tail' called on an empty list", .{});
    return .{ .list = list[1..] };
}

fn primElemAt(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    const n = try forceInt(st, args[1], "");
    if (n < 0 or @as(usize, @intCast(n)) >= list.len) {
        return st.userError("list index {d} is out of bounds", .{n});
    }
    return list[@intCast(n)].*;
}

fn primElem(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const x = args[0].*;
    const list = try forceList(st, args[1], "");
    for (list) |e| {
        if (try st.eqValues(x, e.*)) return .{ .bool_ = true };
    }
    return .{ .bool_ = false };
}

fn primConcatLists(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const lists = try forceList(st, args[0], "");
    var total: usize = 0;
    for (lists) |l| {
        try st.force(l);
        if (l.* != .list) return st.userError("element {s} is not a list", .{eval.EvalState.showType(l.*)});
        total += l.list.len;
    }
    const out = try st.alloc.alloc(*Value, total);
    var off: usize = 0;
    for (lists) |l| {
        @memcpy(out[off .. off + l.list.len], l.list);
        off += l.list.len;
    }
    return .{ .list = out };
}

fn primConcatMap(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    var out = std.array_list.Managed(*Value).init(st.alloc);
    for (list) |elem| {
        const r = try st.apply(fun, elem, pos);
        var rv = r;
        try st.force(&rv);
        if (rv != .list) return st.userError("'concatMap': function returned {s}, expected a list", .{eval.EvalState.showType(rv)});
        try out.appendSlice(rv.list);
    }
    return .{ .list = out.items };
}

fn primAll(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    for (list) |elem| {
        var r = try st.apply(fun, elem, pos);
        if (!try forceBool(st, &r, "")) return .{ .bool_ = false };
    }
    return .{ .bool_ = true };
}

fn primAny(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    for (list) |elem| {
        var r = try st.apply(fun, elem, pos);
        if (try forceBool(st, &r, "")) return .{ .bool_ = true };
    }
    return .{ .bool_ = false };
}

fn primTake(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const n = try forceInt(st, args[0], "");
    const list = try forceList(st, args[1], "");
    if (n < 0) return st.userError("cannot take a negative number of elements", .{});
    const nn = @min(@as(usize, @intCast(n)), list.len);
    return .{ .list = list[0..nn] };
}

fn primDrop(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const n = try forceInt(st, args[0], "");
    const list = try forceList(st, args[1], "");
    if (n < 0) return st.userError("cannot drop a negative number of elements", .{});
    const nn = @min(@as(usize, @intCast(n)), list.len);
    return .{ .list = list[nn..] };
}

fn primReverseList(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    const out = try st.alloc.alloc(*Value, list.len);
    for (list, 0..) |e, i| out[list.len - 1 - i] = e;
    return .{ .list = out };
}

const SortCtx = struct {
    st: *Eval,
    fun: Value,

    fn lt(ctx: SortCtx, a: *Value, b: *Value) bool {
        var r = ctx.st.apply(ctx.fun, a, 0) catch return false;
        r = ctx.st.apply(r, b, 0) catch return false;
        ctx.st.force(&r) catch return false;
        return r == .bool_ and r.bool_;
    }
};

fn primSort(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    const out = try st.alloc.dupe(*Value, list);
    std.mem.sort(*Value, out, SortCtx{ .st = st, .fun = fun }, SortCtx.lt);
    return .{ .list = out };
}

fn primPartition(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    var right = std.array_list.Managed(*Value).init(st.alloc);
    var wrong = std.array_list.Managed(*Value).init(st.alloc);
    for (list) |elem| {
        var r = try st.apply(fun, elem, pos);
        if (try forceBool(st, &r, "")) {
            try right.append(elem);
        } else {
            try wrong.append(elem);
        }
    }
    const items = try st.alloc.alloc(value.Item, 2);
    const rv = try st.alloc.create(Value);
    rv.* = .{ .list = right.items };
    const wv = try st.alloc.create(Value);
    wv.* = .{ .list = wrong.items };
    items[0] = .{ .name = "right", .value = rv };
    items[1] = .{ .name = "wrong", .value = wv };
    return st.mkAttrs(items);
}

fn primGroupBy(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const list = try forceList(st, args[1], "");
    var names = std.array_list.Managed([]const u8).init(st.alloc);
    var groups = std.array_list.Managed(std.array_list.Managed(*Value)).init(st.alloc);
    for (list) |elem| {
        const r = try st.apply(fun, elem, pos);
        var rv = r;
        try st.force(&rv);
        const key = try st.coerceToPlainString(&rv, "while evaluating the grouping function");
        var found: ?usize = null;
        for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, key)) {
                found = i;
                break;
            }
        }
        if (found) |gi| {
            try groups.items[gi].append(elem);
        } else {
            try names.append(key);
            var g = std.array_list.Managed(*Value).init(st.alloc);
            try g.append(elem);
            try groups.append(g);
        }
    }
    const items = try st.alloc.alloc(value.Item, names.items.len);
    for (names.items, 0..) |n, i| {
        const v = try st.alloc.create(Value);
        v.* = .{ .list = groups.items[i].items };
        items[i] = .{ .name = n, .value = v };
    }
    return st.mkAttrs(items);
}

// ---------------------------------------------------------------------------
// Attrset builtins
// ---------------------------------------------------------------------------

fn primAttrNames(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceAttrs(st, args[0], "");
    const out = try st.alloc.alloc(*Value, a.items.len);
    for (a.items, 0..) |it, i| {
        const v = try st.alloc.create(Value);
        v.* = st.mkString(it.name, &.{});
        out[i] = v;
    }
    return .{ .list = out };
}

fn primAttrValues(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceAttrs(st, args[0], "");
    const out = try st.alloc.alloc(*Value, a.items.len);
    for (a.items, 0..) |it, i| out[i] = it.value;
    return .{ .list = out };
}

fn primHasAttr(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const name = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.hasAttr");
    var a = args[1].*;
    try st.force(&a);
    if (a != .attrs) return st.userError("'hasAttr' called on {s}, expected a set", .{eval.EvalState.showType(a)});
    return .{ .bool_ = a.attrs.find(name) != null };
}

fn primGetAttr(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const name = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.getAttr");
    var a = args[1].*;
    try st.force(&a);
    if (a != .attrs) return st.userError("'getAttr' called on {s}, expected a set", .{eval.EvalState.showType(a)});
    const item = a.attrs.find(name) orelse {
        return st.userError("attribute '{s}' missing", .{name});
    };
    return item.*;
}

fn primUnsafeGetAttrPos(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const name = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.unsafeGetAttrPos");
    var a = args[1].*;
    try st.force(&a);
    if (a != .attrs) return st.userError("'unsafeGetAttrPos' called on {s}, expected a set", .{eval.EvalState.showType(a)});
    var item: ?value.Item = null;
    for (a.attrs.items) |it| {
        if (std.mem.eql(u8, it.name, name)) {
            item = it;
            break;
        }
    }
    const it = item orelse return .null_;
    if (it.pos.line == 0) return .null_;
    // Command-line expressions have no real source positions (like Nix).
    if (std.mem.endsWith(u8, it.pos.file, "<command-line>")) return .null_;
    const items = try st.alloc.alloc(value.Item, 3);
    const col_v = try st.alloc.create(Value);
    col_v.* = .{ .int = it.pos.col };
    const file_v = try st.alloc.create(Value);
    file_v.* = st.mkString(it.pos.file, &.{});
    const line_v = try st.alloc.create(Value);
    line_v.* = .{ .int = it.pos.line };
    items[0] = .{ .name = "column", .value = col_v };
    items[1] = .{ .name = "file", .value = file_v };
    items[2] = .{ .name = "line", .value = line_v };
    return st.mkAttrs(items);
}

fn primRemoveAttrs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceAttrs(st, args[0], "");
    const names = try forceList(st, args[1], "");
    var names_str = std.array_list.Managed([]const u8).init(st.alloc);
    for (names) |n| {
        try names_str.append(try forceStringNoCtx(st, n, "while evaluating an element of the attribute name list"));
    }
    var items = std.array_list.Managed(value.Item).init(st.alloc);
    for (a.items) |it| {
        var remove = false;
        for (names_str.items) |n| {
            if (std.mem.eql(u8, it.name, n)) {
                remove = true;
                break;
            }
        }
        if (!remove) try items.append(it);
    }
    return st.mkAttrs(items.items);
}

fn primListToAttrs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const list = try forceList(st, args[0], "");
    var items = std.array_list.Managed(value.Item).init(st.alloc);
    for (list) |e| {
        var ev = e.*;
        try st.force(&ev);
        if (ev != .attrs) return st.userError("'listToAttrs' called on {s}, expected a set", .{eval.EvalState.showType(ev)});
        const name_v = ev.attrs.find("name") orelse return st.userError("attribute 'name' missing", .{});
        const val_v = ev.attrs.find("value") orelse return st.userError("attribute 'value' missing", .{});
        const name = try forceStringNoCtx(st, name_v, "while evaluating the 'name' attribute");
        // Nix keeps the FIRST value for a duplicated name (later entries are
        // silently ignored).
        var dup = false;
        for (items.items) |it| {
            if (std.mem.eql(u8, it.name, name)) {
                dup = true;
                break;
            }
        }
        if (!dup) try items.append(.{ .name = name, .value = val_v });
    }
    return st.mkAttrs(items.items);
}

fn primCatAttrs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const name = try forceStringNoCtx(st, args[0], "");
    const list = try forceList(st, args[1], "");
    var out = std.array_list.Managed(*Value).init(st.alloc);
    for (list) |e| {
        var ev = e.*;
        try st.force(&ev);
        if (ev != .attrs) return st.userError("'catAttrs' called on {s}, expected a set", .{eval.EvalState.showType(ev)});
        if (ev.attrs.find(name)) |v| try out.append(v);
    }
    return .{ .list = out.items };
}

fn primIntersectAttrs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceAttrs(st, args[0], "");
    const b = try forceAttrs(st, args[1], "");
    var items = std.array_list.Managed(value.Item).init(st.alloc);
    for (b.items) |it| {
        if (a.find(it.name) != null) try items.append(it);
    }
    return st.mkAttrs(items.items);
}

fn primZipAttrsWith(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const fun = args[0].*;
    const lists = try forceList(st, args[1], "");
    // collect all keys
    var keys = std.array_list.Managed([]const u8).init(st.alloc);
    var vals = std.array_list.Managed(std.array_list.Managed(*Value)).init(st.alloc);
    for (lists) |l| {
        try st.force(l);
        if (l.* != .attrs) return st.userError("'zipAttrsWith': expected a list of sets", .{});
        for (l.attrs.items) |it| {
            var found: ?usize = null;
            for (keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, it.name)) {
                    found = i;
                    break;
                }
            }
            if (found) |gi| {
                try vals.items[gi].append(it.value);
            } else {
                try keys.append(it.name);
                var g = std.array_list.Managed(*Value).init(st.alloc);
                try g.append(it.value);
                try vals.append(g);
            }
        }
    }
    const items = try st.alloc.alloc(value.Item, keys.items.len);
    for (keys.items, 0..) |k, i| {
        const v = try st.alloc.create(Value);
        v.* = .{ .list = vals.items[i].items };
        const name_v = try st.alloc.create(Value);
        name_v.* = st.mkString(k, &.{});
        // Lazy per-key merge (like Nix): the function application is a thunk.
        const r = try st.mkLazyApply(fun, &.{ name_v, v }, pos);
        items[i] = .{ .name = k, .value = try st.alloc.create(Value) };
        items[i].value.* = r;
    }
    return st.mkAttrs(items);
}

fn primFunctionArgs(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var f = args[0].*;
    try st.force(&f);
    switch (f) {
        .lambda => |lam| {
            var items = std.array_list.Managed(value.Item).init(st.alloc);
            if (lam.params.formals) |formals| {
                for (formals.formals) |formal| {
                    const v = try st.alloc.create(Value);
                    v.* = .{ .bool_ = formal.default != null };
                    try items.append(.{ .name = formal.name, .value = v });
                }
            }
            return st.mkAttrs(items.items);
        },
        .builtin => |b| {
            // Nix returns {} for builtins
            _ = b;
            return st.mkAttrs(&.{});
        },
        else => return st.userError("'functionArgs' called on {s}, expected a function", .{eval.EvalState.showType(f)}),
    }
}

// ---------------------------------------------------------------------------
// String builtins
// ---------------------------------------------------------------------------

fn primStringLength(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    return .{ .int = @intCast(s.len) };
}

fn primSubstring(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const start = try forceInt(st, args[0], "");
    const len = try forceInt(st, args[1], "");
    const s = try forceStringNoCtx(st, args[2], "");
    if (start < 0) return st.userError("negative start position in 'substring'", .{});
    const s_i: usize = @intCast(start);
    if (s_i >= s.len) return st.mkString("", &.{});
    // A negative length means "to the end of the string" (like Nix).
    const l_i: usize = if (len < 0) s.len - s_i else @intCast(len);
    const end = @min(s.len, s_i + l_i);
    return st.mkString(s[s_i..end], &.{});
}

fn primToUpper(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    const out = try st.alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* >= 'a' and c.* <= 'z') c.* -= 32;
    }
    return st.mkString(out, &.{});
}

fn primToLower(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    const out = try st.alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
    return st.mkString(out, &.{});
}

fn primReplaceStrings(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const from = try forceList(st, args[0], "");
    const to = try forceList(st, args[1], "");
    if (from.len != to.len) return st.userError("'replaceStrings' got {d} patterns and {d} replacements", .{ from.len, to.len });
    var from_s = std.array_list.Managed([]const u8).init(st.alloc);
    var to_s = std.array_list.Managed([]const u8).init(st.alloc);
    for (from) |f| try from_s.append(try forceStringNoCtx(st, f, "while evaluating a pattern"));
    for (to) |t| try to_s.append(try forceStringNoCtx(st, t, "while evaluating a replacement"));
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const s = try forceStringWithCtx(st, args[2], &ctx, false, "while evaluating the third argument to builtins.replaceStrings");
    var out = std.array_list.Managed(u8).init(st.alloc);
    var i: usize = 0;
    while (i < s.len) {
        var matched: ?usize = null;
        for (from_s.items, 0..) |pat, pi| {
            if (std.mem.startsWith(u8, s[i..], pat)) {
                matched = pi;
                break;
            }
        }
        if (matched) |pi| {
            try out.appendSlice(to_s.items[pi]);
            i += from_s.items[pi].len;
            if (from_s.items[pi].len == 0) {
                try out.append(s[i]);
                i += 1;
            }
        } else {
            try out.append(s[i]);
            i += 1;
        }
    }
    return st.mkString(try st.alloc.dupe(u8, out.items), ctx.items);
}

fn primConcatStringsSep(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const sep = try forceStringWithCtx(st, args[0], &ctx, false, "while evaluating the separator");
    const list = try forceList(st, args[1], "");
    var out = std.array_list.Managed(u8).init(st.alloc);
    for (list, 0..) |e, i| {
        if (i > 0) try out.appendSlice(sep);
        var ev = e.*;
        const s = try st.coerceToString(&ev, &ctx, false, true, "while evaluating an element");
        try out.appendSlice(s);
    }
    return st.mkString(try st.alloc.dupe(u8, out.items), ctx.items);
}

fn primSplit(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const re = try forceStringNoCtx(st, args[0], "");
    const s = try forceStringNoCtx(st, args[1], "");
    return regexSplit(st, re, s);
}

fn primMatch(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const re = try forceStringNoCtx(st, args[0], "");
    const s = try forceStringNoCtx(st, args[1], "");
    return regexMatch(st, re, s);
}

fn primCompareVersions(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceStringNoCtx(st, args[0], "");
    const b = try forceStringNoCtx(st, args[1], "");
    const cmp = compareVersions(a, b);
    return .{ .int = switch (cmp) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

fn primSplitVersion(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    var comps = std.array_list.Managed(*Value).init(st.alloc);
    var it = VersionIter{ .s = s };
    while (it.next()) |c| {
        const v = try st.alloc.create(Value);
        v.* = st.mkString(c, &.{});
        try comps.append(v);
    }
    return .{ .list = comps.items };
}

fn primParseDrvName(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    var name = s;
    var version: []const u8 = "";
    for (s, 0..) |c, i| {
        if (c == '-' and i + 1 < s.len and !isAlpha(s[i + 1])) {
            name = s[0..i];
            version = s[i + 1 ..];
            break;
        }
    }
    const nv = try st.alloc.create(Value);
    nv.* = st.mkString(name, &.{});
    const vv = try st.alloc.create(Value);
    vv.* = st.mkString(version, &.{});
    const items = try st.alloc.alloc(value.Item, 2);
    items[0] = .{ .name = "name", .value = nv };
    items[1] = .{ .name = "version", .value = vv };
    return st.mkAttrs(items);
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const VersionIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *VersionIter) ?[]const u8 {
        // skip dots and dashes
        while (self.i < self.s.len and (self.s[self.i] == '.' or self.s[self.i] == '-')) self.i += 1;
        if (self.i >= self.s.len) return null;
        const start = self.i;
        if (isDigit(self.s[self.i])) {
            while (self.i < self.s.len and isDigit(self.s[self.i])) self.i += 1;
        } else {
            while (self.i < self.s.len and !isDigit(self.s[self.i]) and self.s[self.i] != '.' and self.s[self.i] != '-') self.i += 1;
        }
        return self.s[start..self.i];
    }
};

fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    var it1 = VersionIter{ .s = a };
    var it2 = VersionIter{ .s = b };
    while (true) {
        const c1 = it1.next();
        const c2 = it2.next();
        if (c1 == null and c2 == null) return .eq;
        const c1s = c1 orelse "";
        const c2s = c2 orelse "";
        if (componentsLT(c1s, c2s)) return .lt;
        if (componentsLT(c2s, c1s)) return .gt;
    }
}

fn componentsLT(c1: []const u8, c2: []const u8) bool {
    const n1 = parseIntOpt(c1);
    const n2 = parseIntOpt(c2);
    if (n1 != null and n2 != null) return n1.? < n2.?;
    if (c1.len == 0 and n2 != null) return true;
    if (std.mem.eql(u8, c1, "pre") and !std.mem.eql(u8, c2, "pre")) return true;
    if (std.mem.eql(u8, c2, "pre")) return false;
    if (n2 != null) return true; // 2.3a < 2.3.1
    if (n1 != null) return false;
    return std.mem.order(u8, c1, c2) == .lt;
}

fn parseIntOpt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    for (s) |c| {
        if (!isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn primBaseNameOf(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const s = try forceStringWithCtx(st, args[0], &ctx, false, "while evaluating the argument to builtins.baseNameOf");
    const base = std.fs.path.basename(s);
    return st.mkString(base, ctx.items);
}

fn primDirOf(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    // Nix preserves the input type: a path argument yields a path, a string
    // (possibly with store context) yields a string.
    switch (v) {
        .path => |p| {
            const dir = std.fs.path.dirname(p.p) orelse ".";
            return .{ .path = .{ .p = try st.alloc.dupe(u8, dir), .ctx = ctx.items } };
        },
        else => {
            const s = try forceStringWithCtx(st, args[0], &ctx, false, "while evaluating the argument to builtins.dirOf");
            const dir = std.fs.path.dirname(s) orelse ".";
            return st.mkString(try st.alloc.dupe(u8, dir), ctx.items);
        },
    }
}

// ---------------------------------------------------------------------------
// Files / store
// ---------------------------------------------------------------------------

fn primReadFile(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'readFile' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    const contents = fsutil.readFileAlloc(st.alloc, p, 1 << 30) catch |e| {
        return st.userError("cannot read file '{s}': {s}", .{ p, @errorName(e) });
    };
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    if (st.store.isInStore(p)) {
        // treat as store path reference
        try ctx.append(.{ .kind = .opaq, .path = p });
    }
    return st.mkString(contents, ctx.items);
}

fn primReadDir(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    if (!st.impure) return st.userError("access to absolute path is forbidden in pure evaluation mode (use '--impure' to override)", .{});

    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'readDir' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    var names = std.array_list.Managed([]const u8).init(st.alloc);
    var kinds = std.array_list.Managed([]const u8).init(st.alloc);
    var dir = std.Io.Dir.cwd().openDir(fsutil.io, p, .{ .iterate = true }) catch |e| {
        return st.userError("cannot read directory '{s}': {s}", .{ p, @errorName(e) });
    };
    defer dir.close(fsutil.io);
    var it2 = dir.iterate();
    while (it2.next(fsutil.io) catch null) |entry| {
        const full = std.fs.path.join(st.alloc, &.{ p, entry.name }) catch return error.OutOfMemory;
        const kind: []const u8 = blk: {
            const stt = fsutil.statPath(full) catch break :blk "unknown";
            break :blk switch (stt.kind) {
                .file => "regular",
                .directory => "directory",
                .symlink => "symlink",
                else => "unknown",
            };
        };
        try names.append(try st.alloc.dupe(u8, entry.name));
        try kinds.append(kind);
    }
    const items = try st.alloc.alloc(value.Item, names.items.len);
    for (names.items, 0..) |n, i| {
        const vv = try st.alloc.create(Value);
        vv.* = st.mkString(kinds.items[i], &.{});
        items[i] = .{ .name = n, .value = vv };
    }
    return st.mkAttrs(items);
}

fn primToFile(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const name = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.toFile");
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const contents = try forceStringWithCtx(st, args[1], &ctx, false, "while evaluating the second argument to builtins.toFile");
    const refs = try st.alloc.alloc([]const u8, ctx.items.len);
    for (ctx.items, 0..) |c, i| refs[i] = c.path;
    const p = st.store.writeText(name, contents, refs) catch |e| {
        return st.userError("cannot write to store: {s}", .{@errorName(e)});
    };
    var ctx2 = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx2.append(.{ .kind = .opaq, .path = p });
    return st.mkString(p, ctx2.items);
}

const PathFilterCtx = struct {
    st: *Eval,
    filter: Value,

    fn apply(ctx: *anyopaque, path: []const u8, kind: []const u8) bool {
        const self: *PathFilterCtx = @ptrCast(@alignCast(ctx));
        const pv = self.st.alloc.create(Value) catch return true;
        pv.* = self.st.mkString(path, &.{});
        const kv = self.st.alloc.create(Value) catch return true;
        kv.* = self.st.mkString(kind, &.{});
        // The filter is curried: `path: type: bool`
        var r = self.st.apply(self.filter, pv, 0) catch return true;
        r = self.st.apply(r, kv, 0) catch return true;
        var rv = r;
        self.st.force(&rv) catch return true;
        return rv == .bool_ and rv.bool_;
    }
};

fn primPath(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.path");
    const path_v = a.find("path") orelse return st.userError("attribute 'path' missing", .{});
    var pv = path_v.*;
    try st.force(&pv);
    const p: []const u8 = switch (pv) {
        .path => |pp| pp.p,
        .string => |s| s.s,
        else => return st.userError("'path' attribute is not a path", .{}),
    };
    var name: []const u8 = std.fs.path.basename(p);
    if (a.find("name")) |nv| {
        var n2 = nv.*;
        name = try forceStringNoCtx(st, &n2, "while evaluating the 'name' attribute");
    }
    var recursive = true;
    if (a.find("recursive")) |rv| {
        var r2 = rv.*;
        recursive = try forceBool(st, &r2, "while evaluating the 'recursive' attribute");
    }
    // Filtered paths: build the filtered NAR, hash it, write it directly.
    if (a.find("filter")) |fv| {
        var f2 = fv.*;
        try st.force(&f2);
        var fctx = PathFilterCtx{ .st = st, .filter = f2 };
        const nar = store.narDumpFiltered(st.alloc, p, &fctx, PathFilterCtx.apply) catch |e| {
            return st.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
        };
        const hash = store.Hash.of(nar);
        const sp = st.store.makeFixedOutputPath(name, .recursive, hash, &.{}) catch |e| {
            return st.userError("cannot compute store path: {s}", .{@errorName(e)});
        };
        if (!st.store.read_only) {
            fsutil.makePath(st.store.store_dir) catch |e| {
                return st.userError("cannot write to store: {s}", .{@errorName(e)});
            };
            fsutil.writeFile(sp, nar) catch |e| {
                return st.userError("cannot write to store: {s}", .{@errorName(e)});
            };
        }
        var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
        try ctx.append(.{ .kind = .opaq, .path = sp });
        return st.mkString(sp, ctx.items);
    }
    var hash: store.Hash = undefined;
    if (recursive) {
        hash = store.hashRecursive(st.alloc, p) catch |e| {
            return st.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
        };
    } else {
        hash = store.hashFlatFile(st.alloc, p) catch |e| {
            return st.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
        };
    }
    if (a.find("sha256")) |hv| {
        var h2 = hv.*;
        try st.force(&h2);
        const hs = try forceStringNoCtx(st, &h2, "while evaluating the 'sha256' attribute");
        const eh = nixhash.parseHash(st.alloc, hs) catch return st.userError("invalid sha256 hash '{s}'", .{hs});
        if (!eh.eql(hash)) {
            return st.userError("hash mismatch: expected {s} but got {s}", .{ try eh.base16(st.alloc), try hash.base16(st.alloc) });
        }
    }
    const sp = st.store.makeFixedOutputPath(name, if (recursive) .recursive else .flat, hash, &.{}) catch |e| {
        return st.userError("cannot compute store path: {s}", .{@errorName(e)});
    };
    if (!st.store.read_only) {
        _ = store.addToStoreWrite(&st.store, name, p, if (recursive) .recursive else .flat) catch |e| {
            return st.userError("cannot write to store: {s}", .{@errorName(e)});
        };
    }
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = sp });
    return st.mkString(sp, ctx.items);
}

fn primPathExists(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'pathExists' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    return .{ .bool_ = fsutil.pathExists(p) };
}

fn primHashString(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const algo = try forceStringNoCtx(st, args[0], "");
    const s = try forceStringNoCtx(st, args[1], "");
    var hex: [256]u8 = undefined;
    const out: []const u8 = if (std.mem.eql(u8, algo, "md5")) blk: {
        var d: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        std.crypto.hash.Md5.hash(s, &d, .{});
        break :blk nixhash.base16Encode(&hex, &d);
    } else if (std.mem.eql(u8, algo, "sha1")) blk: {
        var d: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(s, &d, .{});
        break :blk nixhash.base16Encode(&hex, &d);
    } else if (std.mem.eql(u8, algo, "sha256")) blk: {
        break :blk nixhash.base16Encode(&hex, &nixhash.sha256(s));
    } else if (std.mem.eql(u8, algo, "sha512")) blk: {
        var d: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(s, &d, .{});
        break :blk nixhash.base16Encode(&hex, &d);
    } else {
        return st.userError("unknown hash algorithm '{s}'", .{algo});
    };
    return st.mkString(try st.alloc.dupe(u8, out), &.{});
}

fn primHashFile(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const algo = try forceStringNoCtx(st, args[0], "");
    var v = args[1].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'hashFile' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    if (!std.mem.eql(u8, algo, "sha256")) {
        return st.userError("unknown hash algorithm '{s}'", .{algo});
    }
    const contents = fsutil.readFileAlloc(st.alloc, p, 1 << 30) catch |e| {
        return st.userError("cannot read '{s}': {s}", .{ p, @errorName(e) });
    };
    const h = nixhash.Hash.of(contents);
    return st.mkString(try h.base16(st.alloc), &.{});
}

fn primStorePath(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'storePath' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    if (!st.store.isInStore(p)) {
        return st.userError("path '{s}' is not in the Nix store", .{p});
    }
    if (!fsutil.pathExists(p)) {
        return st.userError("path '{s}' is required, but there is no substitute", .{p});
    }
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = p });
    return st.mkString(p, ctx.items);
}

fn primGetEnv(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    // In pure mode the environment is hidden (like Nix).
    if (!st.impure) return st.mkString("", &.{});

    const name = try forceStringNoCtx(st, args[0], "");
    const val = if (st.environ) |env| env.get(name) orelse "" else "";
    return st.mkString(val, &.{});
}

fn primCurrentSystem(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    if (!st.impure) {
        return st.userError("attribute 'currentSystem' missing", .{});
    }
    _ = args;
    _ = pos;

    const b = @import("builtin");
    return st.mkString(@tagName(b. target.cpu.arch) ++ "-" ++ @tagName(b.target.os.tag), &.{});
}

fn primCurrentTime(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = st;
    _ = args;
    _ = pos;

    // epoch seconds (portable via std.Io.Clock)
    const ts = std.Io.Clock.now(.real, fsutil.io);
    return .{ .int = @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000)) };
}

fn primNixVersion(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = args;
    _ = pos;

    return st.mkString("2.34.7", &.{});
}

fn primLangVersion(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = st;
    _ = args;
    _ = pos;

    return .{ .int = 6 };
}

fn primStoreDir(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = args;
    _ = pos;

    return st.mkString(st.store.store_dir, &.{});
}

fn primNixPath(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    if (!st.impure) return .{ .list = &.{} };
    _ = args;
    _ = pos;

    const out = try st.alloc.alloc(*Value, st.nix_path.len);
    for (st.nix_path, 0..) |entry, i| {
        const items = try st.alloc.alloc(value.Item, 2);
        const pv = try st.alloc.create(Value);
        pv.* = st.mkString(entry.path, &.{});
        const pref = try st.alloc.create(Value);
        pref.* = st.mkString(entry.prefix, &.{});
        items[0] = .{ .name = "path", .value = pv };
        items[1] = .{ .name = "prefix", .value = pref };
        out[i] = try st.alloc.create(Value);
        out[i].* = try st.mkAttrs(items);
    }
    return .{ .list = out };
}

fn primHasContext(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const ctx: []const value.CtxElem = switch (v) {
        .string => |s| s.ctx,
        .path => |p| p.ctx,
        else => return st.userError("'hasContext' called on {s}, expected a string", .{eval.EvalState.showType(v)}),
    };
    return .{ .bool_ = ctx.len > 0 };
}

fn primCeil(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const f: f64 = switch (v) {
        .float => |fv| fv,
        .int => |i| @floatFromInt(i),
        else => return st.userError("'ceil' called on {s}, expected a float", .{eval.EvalState.showType(v)}),
    };
    return .{ .int = @intFromFloat(@ceil(f)) };
}

fn primFloor(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const f: f64 = switch (v) {
        .float => |fv| fv,
        .int => |i| @floatFromInt(i),
        else => return st.userError("'floor' called on {s}, expected a float", .{eval.EvalState.showType(v)}),
    };
    return .{ .int = @intFromFloat(@floor(f)) };
}

fn primReadFileType(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'readFileType' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    const ty = fsutil.pathType(p) orelse return .null_;
    return st.mkString(ty, &.{});
}

fn primWarn(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const msg = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.warn");
    std.debug.print("warning: {s}\n", .{msg});
    return args[1].*;
}

fn primTraceVerbose(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    _ = try forceStringNoCtx(st, args[0], "while evaluating the first argument to builtins.traceVerbose");
    return args[1].*;
}

fn primConvertHash(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    // Nix 2.34 signature: convertHash { hash, hashAlgo?, toHashFormat }.
    var av = args[0].*;
    try st.force(&av);
    if (av != .attrs) return st.userError("'convertHash' called on {s}, expected a set", .{eval.EvalState.showType(av)});
    const h_v = av.attrs.find("hash") orelse return st.userError("attribute 'hash' missing", .{});
    var hv = h_v.*;
    try st.force(&hv);
    const h: []const u8 = switch (hv) {
        .string => |s| s.s,
        else => return st.userError("'hash' is {s}, expected a string", .{eval.EvalState.showType(hv)}),
    };
    // Nix requires the algorithm so it can parse the input hash.
    const algo_v = av.attrs.find("hashAlgo") orelse return st.userError("attribute 'hashAlgo' missing", .{});
    var algov = algo_v.*;
    try st.force(&algov);
    const algo = try forceStringNoCtx(st, &algov, "while evaluating the attribute 'hashAlgo'");
    if (!std.mem.eql(u8, algo, "sha256")) return st.userError("unsupported hash algorithm '{s}'", .{algo});
    const fmt_v = av.attrs.find("toHashFormat") orelse return st.userError("attribute 'toHashFormat' missing", .{});
    var fmtv = fmt_v.*;
    try st.force(&fmtv);
    const to_format = try forceStringNoCtx(st, &fmtv, "while evaluating the attribute 'toHashFormat'");
    if (std.mem.eql(u8, to_format, "base16")) {
        if (h.len == 52) {
            const bytes = nixhash.nix32Decode(st.alloc, h) catch return st.userError("invalid nix32 hash '{s}'", .{h});
            var hex: [70]u8 = undefined;
            return st.mkString(try st.alloc.dupe(u8, nixhash.base16Encode(&hex, bytes)), &.{});
        }
        if (h.len == 64) return st.mkString(try st.alloc.dupe(u8, h), &.{});
        return st.userError("cannot convert hash '{s}'", .{h});
    }
    if (std.mem.eql(u8, to_format, "base32") or std.mem.eql(u8, to_format, "nix32")) {
        if (h.len == 64) {
            const bytes = nixhash.base16Decode(st.alloc, h) catch return st.userError("invalid base16 hash '{s}'", .{h});
            var b32buf: [64]u8 = undefined;
            return st.mkString(try st.alloc.dupe(u8, nixhash.nix32Encode(bytes, &b32buf)), &.{});
        }
        if (h.len == 52) return st.mkString(try st.alloc.dupe(u8, h), &.{});
        return st.userError("cannot convert hash '{s}'", .{h});
    }
    return st.userError("unknown hash format '{s}'", .{to_format});
}

fn primFilterSource(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var fv = args[0].*;
    try st.force(&fv);
    var pv = args[1].*;
    try st.force(&pv);
    const p: []const u8 = switch (pv) {
        .path => |p| p.p,
        else => return st.userError("'filterSource' called on {s}, expected a path", .{eval.EvalState.showType(pv)}),
    };
    const name = std.fs.path.basename(p);
    if (!st.impure) {
        return st.userError("access to absolute path '{s}' is forbidden in pure evaluation mode (use '--impure' to override)", .{p});
    }
    st.filter_fn = fv;
    const sp = store.addPathToStoreFiltered(&st.store, name, p, .{
        .st = st,
        .filterCheck = struct {
            fn f(ctx: *anyopaque, p2: []const u8, kind: []const u8) bool {
                const es: *Eval = @ptrCast(@alignCast(ctx));
                return es.filterCheck(p2, kind);
            }
        }.f,
    }) catch |e| {
        return st.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
    };
    return st.mkString(try st.alloc.dupe(u8, sp), &.{});
}

fn primGetContext(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const ctx: []const value.CtxElem = switch (v) {
        .string => |s| s.ctx,
        .path => |p| p.ctx,
        else => return st.userError("'getContext' called on {s}, expected a string", .{eval.EvalState.showType(v)}),
    };
    var items = std.array_list.Managed(value.Item).init(st.alloc);
    for (ctx) |c| {
        const nv = try st.alloc.create(Value);
        nv.* = st.mkString(c.path, &.{});
        try items.append(.{ .name = c.path, .value = nv });
    }
    return st.mkAttrs(items.items);
}

fn primAppendContext(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const ctx: []const value.CtxElem = switch (v) {
        .string => |s| s.ctx,
        else => return st.userError("'appendContext' called on {s}, expected a string", .{eval.EvalState.showType(v)}),
    };
    const extra = try forceAttrs(st, args[1], "");
    var out_ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try out_ctx.appendSlice(ctx);
    for (extra.items) |it| {
        var ev = it.value.*;
        try st.force(&ev);
        const kind: value.CtxKind = switch (ev) {
            .string => |s| if (std.mem.eql(u8, s.s, "derivation")) .drv_deep else .opaq,
            else => .opaq,
        };
        try out_ctx.append(.{ .kind = kind, .path = it.name });
    }
    return switch (v) {
        .string => |s| st.mkString(s.s, out_ctx.items),
        else => unreachable,
    };
}

fn primImport(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'import' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    return st.importPath(p);
}

fn primScopedImport(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const scope = try forceAttrs(st, args[0], "while evaluating the first argument to builtins.scopedImport");
    var v = args[1].*;
    try st.force(&v);
    const p: []const u8 = switch (v) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'scopedImport' called on {s}, expected a path", .{eval.EvalState.showType(v)}),
    };
    const vars = try st.alloc.alloc(value.Var, scope.items.len);
    for (scope.items, 0..) |it, i| vars[i] = .{ .name = it.name, .value = it.value };
    const scope_env = try st.alloc.create(value.Env);
    scope_env.* = .{ .parent = st.base_env, .vars = vars };
    const resolved = if (fsutil.isDirectory(p)) std.fs.path.join(st.alloc, &.{ p, "default.nix" }) catch return error.OutOfMemory else p;
    const contents = fsutil.readFileAlloc(st.alloc, resolved, 1 << 30) catch |e| {
        return st.userError("cannot read '{s}': {s}", .{ resolved, @errorName(e) });
    };
    const parsed = try st.parse(contents, resolved);
    const prev = st.cur_file;
    st.cur_file = resolved;
    defer st.cur_file = prev;
    return st.eval(parsed, scope_env, 0);
}

fn primTryEval(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const success = try st.alloc.create(Value);
    const valv = try st.alloc.create(Value);
    if (st.tryEval(args[0])) |val| {
        success.* = .{ .bool_ = true };
        valv.* = val;
    } else |_| {
        // Nix only catches assertion failures and `throw`; other errors
        // propagate. `value = false` is Nix's historical placeholder.
        if (st.err_kind == .assert or st.err_kind == .thrown) {
            success.* = .{ .bool_ = false };
            valv.* = .{ .bool_ = false };
        } else {
            return error.UserError;
        }
    }
    const items = try st.alloc.alloc(value.Item, 2);
    items[0] = .{ .name = "success", .value = success };
    items[1] = .{ .name = "value", .value = valv };
    return st.mkAttrs(items);
}

fn primGenericClosure(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const a = try forceAttrs(st, args[0], "");
    const start_v = a.find("startSet") orelse return st.userError("attribute 'startSet' missing", .{});
    const op_v = a.find("operator") orelse return st.userError("attribute 'operator' missing", .{});
    const start = try forceList(st, start_v, "");
    var res = std.array_list.Managed(*Value).init(st.alloc);
    var seen = std.StringHashMap(void).init(st.alloc);
    var queue = std.array_list.Managed(*Value).init(st.alloc);
    try queue.appendSlice(start);
    while (queue.items.len > 0) {
        const cur = queue.pop().?;
        var cv = cur.*;
        try st.force(&cv);
        if (cv != .attrs) return st.userError("'genericClosure': element is not a set", .{});
        const key_v = cv.attrs.find("key") orelse return st.userError("attribute 'key' missing", .{});
        var kv = key_v.*;
        try st.force(&kv);
        const key = try st.coerceToLooseString(&kv, "while evaluating the 'key' attribute");
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        try res.append(cur);
        const r = try st.apply(op_v.*, cur, pos);
        var rv = r;
        try st.force(&rv);
        if (rv != .list) return st.userError("'genericClosure': operator returned {s}, expected a list", .{eval.EvalState.showType(rv)});
        try queue.appendSlice(rv.list);
    }
    return .{ .list = res.items };
}

fn primUnsafeDiscardStringContext(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    try st.force(&v);
    return switch (v) {
        .string => |s| st.mkString(s.s, &.{}),
        else => v,
    };
}

// ---------------------------------------------------------------------------
// Fetching (curl subprocess; documented dependency)
// ---------------------------------------------------------------------------

fn curlDownload(st: *Eval, url: []const u8, dest: []const u8) EvalError!void {
    var argv = std.array_list.Managed([]const u8).init(st.alloc);
    try argv.appendSlice(&.{ "curl", "-L", "-sS", "-o", dest, url });
    var child = std.process.spawn(fsutil.io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .inherit,
        .stdin = .ignore,
    }) catch |e| {
        return st.userError("cannot run curl: {s}", .{@errorName(e)});
    };
    const term = child.wait(fsutil.io) catch return st.userError("curl failed", .{});
    switch (term) {
        .exited => |code| if (code != 0) return st.userError("curl failed to download '{s}' (exit {d})", .{ url, code }),
        else => return st.userError("curl terminated abnormally", .{}),
    }
}

fn fetchArgs(st: *Eval, a: *value.Attrs, what: []const u8) EvalError!struct { url: []const u8, name: []const u8, hash: ?[]const u8 } {
    const url_v = a.find("url") orelse return st.userError("attribute 'url' missing in builtins.{s}", .{what});
    var uv = url_v.*;
    const url = try forceStringNoCtx(st, &uv, "while evaluating the 'url' attribute");
    var name: []const u8 = "source";
    if (a.find("name")) |nv| {
        var n2 = nv.*;
        name = try forceStringNoCtx(st, &n2, "while evaluating the 'name' attribute");
    }
    var hash: ?[]const u8 = null;
    if (a.find("sha256")) |hv| {
        var h2 = hv.*;
        hash = try forceStringNoCtx(st, &h2, "while evaluating the 'sha256' attribute");
    } else if (a.find("narHash")) |hv| {
        var h2 = hv.*;
        hash = try forceStringNoCtx(st, &h2, "while evaluating the 'narHash' attribute");
    }
    return .{ .url = url, .name = name, .hash = hash };
}

fn primFetchurl(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.fetchurl");
    const fa = try fetchArgs(st, a, "fetchurl");
    const tmp = try std.fmt.allocPrint(st.alloc, "/tmp/zix-fetch-{d}", .{std.Io.Clock.now(.real, fsutil.io).nanoseconds});
    try curlDownload(st, fa.url, tmp);
    const contents = fsutil.readFileAlloc(st.alloc, tmp, 1 << 30) catch |e| {
        return st.userError("cannot read downloaded file: {s}", .{@errorName(e)});
    };
    const hash = store.Hash.of(contents);
    if (fa.hash) |hs| {
        const eh = nixhash.parseHash(st.alloc, hs) catch return st.userError("invalid hash '{s}'", .{hs});
        if (!eh.eql(hash)) {
            return st.userError("hash mismatch in builtins.fetchurl: expected {s} but got {s}", .{ try eh.base16(st.alloc), try hash.base16(st.alloc) });
        }
    }
    const sp = st.store.makeFixedOutputPath(fa.name, .flat, hash, &.{}) catch |e| {
        return st.userError("cannot compute store path: {s}", .{@errorName(e)});
    };
    if (!st.store.read_only) {
        fsutil.makePath(st.store.store_dir) catch {};
        fsutil.writeFile(sp, contents) catch |e| {
            return st.userError("cannot write to store: {s}", .{@errorName(e)});
        };
    }
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = sp });
    return st.mkString(sp, ctx.items);
}

fn primFetchTarball(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.fetchTarball");
    const fa = try fetchArgs(st, a, "fetchTarball");
    const stamp = std.Io.Clock.now(.real, fsutil.io).nanoseconds;
    const tmp = try std.fmt.allocPrint(st.alloc, "/tmp/zix-fetch-{d}", .{stamp});
    const dir = try std.fmt.allocPrint(st.alloc, "/tmp/zix-fetch-dir-{d}", .{stamp});
    try curlDownload(st, fa.url, tmp);
    // unpack: tar auto-detects .tar.gz/.zip
    var argv = std.array_list.Managed([]const u8).init(st.alloc);
    try argv.appendSlice(&.{ "tar", "-xf", tmp, "-C", dir });
    fsutil.makePath(dir) catch {};
    var child = std.process.spawn(fsutil.io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .inherit,
        .stdin = .ignore,
    }) catch |e| {
        return st.userError("cannot run tar: {s}", .{@errorName(e)});
    };
    const term = child.wait(fsutil.io) catch return st.userError("tar failed", .{});
    switch (term) {
        .exited => |code| if (code != 0) return st.userError("tar failed to unpack '{s}' (exit {d})", .{ fa.url, code }),
        else => return st.userError("tar terminated abnormally", .{}),
    }
    // The `sha256`/`narHash` attribute is the NAR hash of the unpacked source
    // tree.  Like Nix, if the tarball has a single top-level entry we hash
    // that entry (the tarball root) rather than the extraction wrapper dir.
    var root = dir;
    const names = fsutil.readDirNames(st.alloc, dir) catch return st.userError("cannot read unpacked tarball", .{});
    if (names.len == 1) {
        root = try std.fs.path.join(st.alloc, &.{ dir, names[0] });
    }
    const hash = store.hashRecursive(st.alloc, root) catch return st.userError("cannot hash unpacked tarball", .{});
    if (fa.hash) |hs| {
        const eh = nixhash.parseHash(st.alloc, hs) catch return st.userError("invalid hash '{s}'", .{hs});
        if (!eh.eql(hash)) {
            return st.userError("hash mismatch in builtins.fetchTarball: expected {s} but got {s}", .{ try eh.base16(st.alloc), try hash.base16(st.alloc) });
        }
    }
    const sp = st.store.makeFixedOutputPath(fa.name, .recursive, hash, &.{}) catch |e| {
        return st.userError("cannot compute store path: {s}", .{@errorName(e)});
    };
    if (!st.store.read_only) {
        fsutil.makePath(st.store.store_dir) catch {};
        _ = store.addToStoreWrite(&st.store, fa.name, dir, .recursive) catch |e| {
            return st.userError("cannot write to store: {s}", .{@errorName(e)});
        };
    }
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = sp });
    return st.mkString(sp, ctx.items);
}

fn runGit(st: *Eval, args: []const []const u8, what: []const u8) EvalError!void {
    var argv = std.array_list.Managed([]const u8).init(st.alloc);
    try argv.append("git");
    for (args) |a| try argv.append(a);
    var child = std.process.spawn(fsutil.io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .inherit,
        .stdin = .ignore,
    }) catch |e| {
        return st.userError("cannot run git: {s}", .{@errorName(e)});
    };
    const term = child.wait(fsutil.io) catch return st.userError("git failed", .{});
    switch (term) {
        .exited => |code| if (code != 0) return st.userError("git {s} failed (exit {d})", .{ what, code }),
        else => return st.userError("git {s} terminated abnormally", .{what}),
    }
}

fn primFetchGit(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.fetchGit");
    const url_v = a.find("url") orelse return st.userError("attribute 'url' missing in builtins.fetchGit", .{});
    var uv = url_v.*;
    const url = try forceStringNoCtx(st, &uv, "while evaluating the 'url' attribute");
    var name: []const u8 = "source";
    if (a.find("name")) |nv| {
        var n2 = nv.*;
        name = try forceStringNoCtx(st, &n2, "while evaluating the 'name' attribute");
    }
    var rev: ?[]const u8 = null;
    if (a.find("rev")) |rv| {
        var r2 = rv.*;
        rev = try forceStringNoCtx(st, &r2, "while evaluating the 'rev' attribute");
    }
    var ref_name: ?[]const u8 = null;
    if (a.find("ref")) |rv| {
        var r2 = rv.*;
        ref_name = try forceStringNoCtx(st, &r2, "while evaluating the 'ref' attribute");
    }
    const stamp = std.Io.Clock.now(.real, fsutil.io).nanoseconds;
    const dir = try std.fmt.allocPrint(st.alloc, "/tmp/zix-git-{d}", .{stamp});
    fsutil.makePath(dir) catch {};
    try runGit(st, &.{ "clone", "--quiet", url, dir }, "clone");
    if (rev) |r| {
        try runGit(st, &.{ "-C", dir, "checkout", "--quiet", r }, "checkout");
    } else if (ref_name) |rf| {
        try runGit(st, &.{ "-C", dir, "checkout", "--quiet", rf }, "checkout");
    }
    const hash = store.hashRecursive(st.alloc, dir) catch return st.userError("cannot hash git tree", .{});
    const sp = st.store.makeFixedOutputPath(name, .recursive, hash, &.{}) catch |e| {
        return st.userError("cannot compute store path: {s}", .{@errorName(e)});
    };
    if (!st.store.read_only) {
        fsutil.makePath(st.store.store_dir) catch {};
        _ = store.addToStoreWrite(&st.store, name, dir, .recursive) catch |e| {
            return st.userError("cannot write to store: {s}", .{@errorName(e)});
        };
    }
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = sp });
    return st.mkString(sp, ctx.items);
}

// ---------------------------------------------------------------------------
// Derivations
// ---------------------------------------------------------------------------

fn hashPlaceholder(st: *Eval, output_name: []const u8) EvalError![]const u8 {
    const h = nixhash.Hash.of(std.fmt.allocPrint(st.alloc, "nix-output:{s}", .{output_name}) catch return error.OutOfMemory);
    const b32 = try h.nix32(st.alloc);
    return std.fmt.allocPrint(st.alloc, "/{s}", .{b32});
}

fn primPlaceholder(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const name = try forceStringNoCtx(st, args[0], "while evaluating the first argument passed to builtins.placeholder");
    return st.mkString(try hashPlaceholder(st, name), &.{});
}

const DrvReadCtx = struct {
    st: *Eval,
    fn read(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) error{ OutOfMemory, IoError, ParseError, StoreError }!drvmod.Derivation {
        const self: *DrvReadCtx = @ptrCast(@alignCast(ctx));
        _ = alloc;
        return readDrvFromStore(self.st, path) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreError,
        };
    }
};

fn readDrvFromStore(st: *Eval, path: []const u8) EvalError!drvmod.Derivation {
    if (!st.store.isInStore(path)) return st.userError("'{s}' is not in the store", .{path});
    const contents = fsutil.readFileAlloc(st.alloc, path, 1 << 30) catch |e| {
        return st.userError("cannot read '{s}': {s}", .{ path, @errorName(e) });
    };
    var d = drvmod.parseDerivation(st.alloc, contents) catch |e| {
        return st.userError("cannot parse derivation '{s}': {s}", .{ path, @errorName(e) });
    };
    // recover the drv name from the path
    d.name = st.store.storePathName(path) orelse return st.userError("bad store path '{s}'", .{path});
    return d;
}

fn primDerivationStrict(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {

    const attrs = try forceAttrs(st, args[0], "while evaluating the argument passed to builtins.derivationStrict");
    const name_v = attrs.find("name") orelse return st.userError("attribute 'name' missing", .{});
    const drv_name = try forceStringNoCtx(st, name_v, "while evaluating the 'name' attribute");
    return derivationStrictInternal(st, drv_name, attrs, pos);
}

fn derivationStrictInternal(st: *Eval, drv_name: []const u8, attrs: *value.Attrs, pos: usize) EvalError!Value {
    _ = pos;

    store.checkName(drv_name) catch return st.userError("invalid derivation name '{s}'", .{drv_name});
    var ignore_nulls = false;
    if (attrs.find("__ignoreNulls")) |v| ignore_nulls = try forceBool(st, v, "");

        var structured_attrs = false;
    var json_entries = std.array_list.Managed(value.Item).init(st.alloc);
var env = std.array_list.Managed(drvmod.EnvPair).init(st.alloc);
    var args_list = std.array_list.Managed([]const u8).init(st.alloc);
    var context = std.array_list.Managed(value.CtxElem).init(st.alloc);
    var content_addressed = false;
    var is_impure = false;
    var floating_hash = false;
    var output_hash: ?[]const u8 = null;
    var output_hash_algo: []const u8 = "sha256";
    var ingestion_method: ?store.FileIngestionMethod = null;
    var outputs = std.array_list.Managed([]const u8).init(st.alloc);
    try outputs.append("out");
    var builder: []const u8 = "";
    var platform: []const u8 = "";

    for (attrs.items) |it| {
        if (std.mem.eql(u8, it.name, "__ignoreNulls")) continue;
        var v = it.value.*;
        if (ignore_nulls) {
            try st.force(&v);
            if (v == .null_) continue;
        }
        if (std.mem.eql(u8, it.name, "__contentAddressed")) {
            if (try forceBool(st, &v, "")) content_addressed = true;
            continue;
        }
        if (std.mem.eql(u8, it.name, "__impure")) {
            if (try forceBool(st, &v, "")) is_impure = true;
            continue;
        }
        if (std.mem.eql(u8, it.name, "args")) {
            try st.force(&v);
            if (v != .list) return st.userError("attribute 'args' is not a list", .{});
            for (v.list) |elem| {
                var ev = elem.*;
                const s = try st.coerceToString(&ev, &context, true, true, "while evaluating an element of the argument list");
                try args_list.append(s);
            }
            continue;
        }
        // default: environment variable (coerced with store copying)
        if (structured_attrs) {
            // With `__structuredAttrs` the attribute goes into the JSON
            // environment verbatim (sets are fine); only the few attrs the
            // build machinery needs (builder, system, out, ...) are also
            // coerced to strings.
            const copy = try st.alloc.create(Value);
            copy.* = v;
            try json_entries.append(.{ .name = it.name, .value = copy });
            const s = st.coerceToString(&v, &context, true, true, "while evaluating a derivation attribute") catch {
                // Sets are valid in the structured JSON but not as env strings;
                // skip the env entry (like Nix).
                continue;
            };
            try env.append(.{ .name = it.name, .value = s });
            if (std.mem.eql(u8, it.name, "builder")) builder = s;
            if (std.mem.eql(u8, it.name, "system")) platform = s;
            continue;
        }
        const s = try st.coerceToString(&v, &context, true, true, "while evaluating a derivation attribute");
        try env.append(.{ .name = it.name, .value = s });
        if (std.mem.eql(u8, it.name, "builder")) builder = s;
        if (std.mem.eql(u8, it.name, "system")) platform = s;
        if (std.mem.eql(u8, it.name, "outputHash")) output_hash = s;
        if (std.mem.eql(u8, it.name, "outputHashAlgo")) output_hash_algo = s;
        if (std.mem.eql(u8, it.name, "outputHashMode")) {
            if (std.mem.eql(u8, s, "recursive") or std.mem.eql(u8, s, "nar")) {
                ingestion_method = .recursive;
            } else if (std.mem.eql(u8, s, "flat")) {
                ingestion_method = .flat;
            } else {
                return st.userError("invalid value '{s}' for 'outputHashMode' attribute", .{s});
            }
        }
        if (std.mem.eql(u8, it.name, "__structuredAttrs")) {
            try st.force(&v);
            structured_attrs = v == .bool_ and v.bool_;
            continue;
        }
        if (std.mem.eql(u8, it.name, "outputs")) {
            outputs.clearRetainingCapacity();
            var it_tok = std.mem.tokenizeAny(u8, s, " \t\n");
            while (it_tok.next()) |o| try outputs.append(o);
            if (outputs.items.len == 0) return st.userError("derivation cannot have an empty set of outputs", .{});
        }
        // Metadata and control attributes are not environment variables
        // (mirrors Nix's derivationStrict).
        if (std.mem.eql(u8, it.name, "meta") or
            std.mem.eql(u8, it.name, "passthru") or
            std.mem.eql(u8, it.name, "preferLocalBuild") or
            std.mem.eql(u8, it.name, "allowSubstitutes") or
            std.mem.eql(u8, it.name, "requiredSystemFeatures") or
            std.mem.eql(u8, it.name, "impureEnvVars") or
            std.mem.eql(u8, it.name, "passAsFile") or
            std.mem.eql(u8, it.name, "allowedReferences") or
            std.mem.eql(u8, it.name, "disallowedReferences") or
            std.mem.eql(u8, it.name, "allowedRequisites") or
            std.mem.eql(u8, it.name, "disallowedRequisites") or
            std.mem.eql(u8, it.name, "exportReferencesGraph") or
            std.mem.eql(u8, it.name, "__darwinAllowLocalNetworking") or
            std.mem.eql(u8, it.name, "__json"))
        {
            continue;
        }
    }

    if (structured_attrs) {
        var jw = std.array_list.Managed(u8).init(st.alloc);
        try jw.appendSlice("{");
        for (json_entries.items, 0..) |je, idx| {
            if (idx > 0) try jw.appendSlice(",");
            try jw.appendSlice("\"");
            try jw.appendSlice(escapeJsonString(je.name));
            try jw.appendSlice("\":");
            try jsonWrite(st, je.value, &jw);
        }
        try jw.appendSlice("}");
        try env.append(.{ .name = "__json", .value = try st.alloc.dupe(u8, jw.items) });
    }

    if (builder.len == 0) return st.userError("required attribute 'builder' missing", .{});
    if (platform.len == 0) return st.userError("required attribute 'system' missing", .{});

    // Inputs from context
    var input_drvs = std.array_list.Managed(drvmod.InputDrv).init(st.alloc);
    var input_srcs = std.array_list.Managed([]const u8).init(st.alloc);
    for (context.items) |c| {
        switch (c.kind) {
            .opaq => try input_srcs.append(c.path),
            .drv_out => {
                var found = false;
                for (input_drvs.items) |*id| {
                    if (std.mem.eql(u8, id.path, c.path)) {
                        id.outputs = try appendStr(st, id.outputs, c.output);
                        found = true;
                        break;
                    }
                }
                if (!found) try input_drvs.append(.{ .path = c.path, .outputs = &.{c.output} });
            },
            .drv_deep => {
                try input_srcs.append(c.path);
                const idrv = readDrvFromStore(st, c.path) catch |e| return e;
                var outnames = std.array_list.Managed([]const u8).init(st.alloc);
                for (idrv.outputs) |o| try outnames.append(o.name);
                try input_drvs.append(.{ .path = c.path, .outputs = outnames.items });
            },
        }
    }

    // Outputs
    var drv_outputs = std.array_list.Managed(drvmod.Output).init(st.alloc);
    if (output_hash) |oh| {
        if (oh.len == 0) {
            // Floating content-addressed derivation: the hash is filled in at
            // build time.  Nix requires the algorithm to be explicit.
            if (output_hash_algo.len == 0) {
                return st.userError("empty hash requires explicit hash algorithm", .{});
            }
            floating_hash = true;
            const method = ingestion_method orelse .recursive;
            const algo_str = try std.fmt.allocPrint(st.alloc, "{s}sha256", .{store.ingestionPrefix(method)});
            // Like Nix's CAFloating: the output path is computed from the
            // derivation hash; the drv records the zero hash.  The env `out`
            // entry is added now (before the env sort) and replaced with the
            // real path once the drv hash is known.
            const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
            try setEnv(st, &env, "out", try hashPlaceholder(st, "out"));
            try drv_outputs.append(.{ .name = "out", .path = "", .hash_algo = algo_str, .hash = zeros });
        } else {
        // fixed-output derivation
        if (outputs.items.len != 1 or !std.mem.eql(u8, outputs.items[0], "out")) {
            return st.userError("multiple outputs are not supported in fixed-output derivations", .{});
        }
        // SRI hashes (`sha256-<b32>`) may omit outputHashAlgo entirely; when
        // given, it must be sha256 (the only algorithm zix supports).
        if (output_hash_algo.len > 0 and !std.mem.eql(u8, output_hash_algo, "sha256")) {
            return st.userError("unsupported hash algorithm '{s}' (zix only supports sha256)", .{output_hash_algo});
        }
            const hash = nixhash.parseHash(st.alloc, oh) catch return st.userError("invalid hash '{s}'", .{oh});
            const method = ingestion_method orelse .flat;
            const out_path = st.store.makeFixedOutputPath(drv_name, method, hash, &.{}) catch |e| {
                return st.userError("cannot compute output path: {s}", .{@errorName(e)});
            };
            try setEnv(st, &env, "out", out_path);
            const algo_str = try std.fmt.allocPrint(st.alloc, "{s}sha256", .{store.ingestionPrefix(method)});
            const hex = try hash.base16(st.alloc);
            try drv_outputs.append(.{ .name = "out", .path = out_path, .hash_algo = algo_str, .hash = hex });
        }
    } else if (content_addressed or is_impure) {
        const method = ingestion_method orelse .recursive;
        const algo_str = try std.fmt.allocPrint(st.alloc, "{s}sha256", .{store.ingestionPrefix(method)});
        for (outputs.items) |o| {
            try setEnv(st, &env, o, try hashPlaceholder(st, o));
            try drv_outputs.append(.{ .name = o, .path = "", .hash_algo = algo_str, .hash = "" });
        }
    } else {
        // input-addressed: deferred outputs, then compute via hashDerivationModulo
        for (outputs.items) |o| {
            try setEnv(st, &env, o, "");
            try drv_outputs.append(.{ .name = o, .path = "", .hash_algo = "", .hash = "" });
        }
    }

    // Sort env / outputs / inputs
    std.mem.sort(drvmod.EnvPair, env.items, {}, struct {
        fn lt(_: void, a: drvmod.EnvPair, b: drvmod.EnvPair) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    std.mem.sort(drvmod.Output, drv_outputs.items, {}, struct {
        fn lt(_: void, a: drvmod.Output, b: drvmod.Output) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    std.mem.sort(drvmod.InputDrv, input_drvs.items, {}, struct {
        fn lt(_: void, a: drvmod.InputDrv, b: drvmod.InputDrv) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);

    var drv = drvmod.Derivation{
        .name = drv_name,
        .outputs = drv_outputs.items,
        .input_drvs = input_drvs.items,
        .input_srcs = input_srcs.items,
        .platform = platform,
        .builder = builder,
        .args = args_list.items,
        .env = env.items,
    };

    // Compute output paths for input-addressed derivations.
    if ((output_hash == null or floating_hash) and !content_addressed and !is_impure) {
        var memo = std.StringHashMap(nixhash.Hash).init(st.alloc);
        var read_ctx = DrvReadCtx{ .st = st };
        const outs = drvmod.hashDerivationModulo(st.alloc, &st.store, &drv, true, DrvReadCtx.read, &read_ctx, &memo) catch |e| {
            return st.userError("cannot compute derivation hash: {s}", .{@errorName(e)});
        };
        for (outs) |o| {
            const p = st.store.makeOutputPath(o.name, o.hash, drv_name) catch |e| {
                return st.userError("cannot compute output path: {s}", .{@errorName(e)});
            };
            try setEnv(st, &env, o.name, p);
            for (drv_outputs.items) |*d| {
                if (std.mem.eql(u8, d.name, o.name)) d.path = p;
            }
        }
        drv.env = env.items;
        drv.outputs = drv_outputs.items;
    }

    // Write the .drv file.
    const contents = try drv.unparse(st.alloc, &st.store, false, null);
    var refs = std.array_list.Managed([]const u8).init(st.alloc);
    try refs.appendSlice(input_srcs.items);
    for (input_drvs.items) |id| try refs.append(id.path);
    if (st.environ != null and st.environ.?.get("ZIX_DEBUG_DRV") != null) {
        std.debug.print("DRVCONTENT: {s}\n", .{contents});
        std.debug.print("DRVREFS: {any}\n", .{refs.items});
    }
    const drv_file_name = try std.fmt.allocPrint(st.alloc, "{s}.drv", .{drv_name});
    // Read-only mode: compute the path without writing it (like `nix eval`).
    const drv_path = if (st.store.read_only)
        st.store.makeTextPath(drv_file_name, nixhash.Hash.of(contents), refs.items) catch |e| {
            return st.userError("cannot compute derivation path: {s}", .{@errorName(e)});
        }
    else
        st.store.writeText(drv_file_name, contents, refs.items) catch |e| {
            return st.userError("cannot write derivation to store: {s}", .{@errorName(e)});
        };

    // Result: { drvPath, <outputs> }
    const n = drv_outputs.items.len + 1;
    const items = try st.alloc.alloc(value.Item, n);
    const drvp_ctx = try st.alloc.alloc(value.CtxElem, 1);
    drvp_ctx[0] = .{ .kind = .drv_deep, .path = drv_path };
    const drvp_v = try st.alloc.create(Value);
    drvp_v.* = st.mkString(drv_path, drvp_ctx);
    items[0] = .{ .name = "drvPath", .value = drvp_v };
    for (drv_outputs.items, 0..) |o, i| {
        const v = try st.alloc.create(Value);
        const octx = try st.alloc.alloc(value.CtxElem, 1);
        octx[0] = .{ .kind = .drv_out, .path = drv_path, .output = o.name };
        v.* = st.mkString(o.path, octx);
        items[i + 1] = .{ .name = o.name, .value = v };
    }
    return st.mkAttrs(items);
}

fn appendStr(st: *Eval, list: []const []const u8, s: []const u8) ![]const []const u8 {
    const out = try st.alloc.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = s;
    return out;
}

fn setEnv(st: *Eval, env: *std.array_list.Managed(drvmod.EnvPair), name: []const u8, val: []const u8) EvalError!void {
    _ = st;
    for (env.items) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            e.value = val;
            return;
        }
    }
    try env.append(.{ .name = name, .value = val });
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

fn escapeJsonString(s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice("\"") catch {},
            '\\' => out.appendSlice("\\\\") catch {},
            '\n' => out.appendSlice("\\n") catch {},
            '\r' => out.appendSlice("\\r") catch {},
            '\t' => out.appendSlice("\\t") catch {},
            else => out.append(c) catch {},
        }
    }
    return out.toOwnedSlice() catch "";
}

pub fn jsonWritePub(st: *Eval, v: *Value, w: *std.array_list.Managed(u8)) EvalError!void {
    return jsonWrite(st, v, w);
}

fn jsonWrite(st: *Eval, v: *Value, w: *std.array_list.Managed(u8)) EvalError!void {
    st.json_depth += 1;
    defer st.json_depth -= 1;
    if (st.json_depth > 10000) return st.userError("JSON value is too deeply nested (cyclic?)", .{});
    try st.force(v);
    switch (v.*) {
        .int => |i| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{i})),
        .float => |f| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "{d}", .{f})),
        .bool_ => |b| try w.appendSlice(if (b) "true" else "false"),
        .null_ => try w.appendSlice("null"),
        .string => |s| {
            try w.append('"');
            for (s.s) |c| {
                switch (c) {
                    '"' => try w.appendSlice("\\\""),
                    '\\' => try w.appendSlice("\\\\"),
                    '\n' => try w.appendSlice("\\n"),
                    '\r' => try w.appendSlice("\\r"),
                    '\t' => try w.appendSlice("\\t"),
                    else => {
                        if (c < 0x20) {
                            try w.appendSlice(try std.fmt.allocPrint(st.alloc, "\\u{x:0>4}", .{c}));
                        } else {
                            try w.append(c);
                        }
                    },
                }
            }
            try w.append('"');
        },
        .list => |l| {
            try w.append('[');
            for (l, 0..) |e, i| {
                if (i > 0) try w.append(',');
                try jsonWrite(st, e, w);
            }
            try w.append(']');
        },
        .attrs => |a| {
            try w.append('{');
            for (a.items, 0..) |it, i| {
                if (i > 0) try w.append(',');
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "\"{s}\":", .{it.name}));
                try jsonWrite(st, it.value, w);
            }
            try w.append('}');
        },
        .lambda => {
            return st.userError("cannot convert a function to JSON", .{});
        },
        else => return st.userError("cannot convert {s} to JSON", .{eval.EvalState.showType(v.*)}),
    }
}

fn primToJSON(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    var v = args[0].*;
    var w = std.array_list.Managed(u8).init(st.alloc);
    try jsonWrite(st, &v, &w);
    return st.mkString(try st.alloc.dupe(u8, w.items), &.{});
}

const JsonParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn skipWs(self: *JsonParser) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\n' or self.s[self.i] == '\t' or self.s[self.i] == '\r')) self.i += 1;
    }

    fn parseValue(self: *JsonParser, st: *Eval) EvalError!Value {
        self.skipWs();
        if (self.i >= self.s.len) return st.userError("unexpected end of JSON", .{});
        switch (self.s[self.i]) {
            '{' => {
                self.i += 1;
                var items = std.array_list.Managed(value.Item).init(self.alloc);
                self.skipWs();
                if (self.i < self.s.len and self.s[self.i] == '}') {
                    self.i += 1;
                    return st.mkAttrs(items.items);
                }
                while (true) {
                    self.skipWs();
                    const name = try self.parseString(st);
                    self.skipWs();
                    if (self.i >= self.s.len or self.s[self.i] != ':') return st.userError("expected ':' in JSON object", .{});
                    self.i += 1;
                    const val = try self.parseValue(st);
                    const v = try self.alloc.create(Value);
                    v.* = val;
                    try items.append(.{ .name = name, .value = v });
                    self.skipWs();
                    if (self.i >= self.s.len) return st.userError("unterminated JSON object", .{});
                    if (self.s[self.i] == ',') {
                        self.i += 1;
                        continue;
                    }
                    if (self.s[self.i] == '}') {
                        self.i += 1;
                        break;
                    }
                    return st.userError("expected ',' or '}}' in JSON object", .{});
                }
                return st.mkAttrs(items.items);
            },
            '[' => {
                self.i += 1;
                var elems = std.array_list.Managed(*Value).init(self.alloc);
                self.skipWs();
                if (self.i < self.s.len and self.s[self.i] == ']') {
                    self.i += 1;
                    return .{ .list = elems.items };
                }
                while (true) {
                    const val = try self.parseValue(st);
                    const v = try self.alloc.create(Value);
                    v.* = val;
                    try elems.append(v);
                    self.skipWs();
                    if (self.i >= self.s.len) return st.userError("unterminated JSON array", .{});
                    if (self.s[self.i] == ',') {
                        self.i += 1;
                        continue;
                    }
                    if (self.s[self.i] == ']') {
                        self.i += 1;
                        break;
                    }
                    return st.userError("expected ',' or ']' in JSON array", .{});
                }
                return .{ .list = elems.items };
            },
            '"' => return st.mkString(try self.parseString(st), &.{}),
            't' => {
                if (self.s.len >= self.i + 4 and std.mem.eql(u8, self.s[self.i .. self.i + 4], "true")) {
                    self.i += 4;
                    return .{ .bool_ = true };
                }
                return st.userError("invalid JSON", .{});
            },
            'f' => {
                if (self.s.len >= self.i + 5 and std.mem.eql(u8, self.s[self.i .. self.i + 5], "false")) {
                    self.i += 5;
                    return .{ .bool_ = false };
                }
                return st.userError("invalid JSON", .{});
            },
            'n' => {
                if (self.s.len >= self.i + 4 and std.mem.eql(u8, self.s[self.i .. self.i + 4], "null")) {
                    self.i += 4;
                    return .null_;
                }
                return st.userError("invalid JSON", .{});
            },
            else => {
                // number
                const start = self.i;
                if (self.s[self.i] == '-') self.i += 1;
                while (self.i < self.s.len and ((self.s[self.i] >= '0' and self.s[self.i] <= '9') or self.s[self.i] == '.' or self.s[self.i] == 'e' or self.s[self.i] == 'E' or self.s[self.i] == '+' or self.s[self.i] == '-')) self.i += 1;
                const text = self.s[start..self.i];
                if (std.mem.indexOfScalar(u8, text, '.') != null or std.mem.indexOfScalar(u8, text, 'e') != null or std.mem.indexOfScalar(u8, text, 'E') != null) {
                    const f = std.fmt.parseFloat(f64, text) catch return st.userError("invalid JSON number", .{});
                    return .{ .float = f };
                }
                const n = std.fmt.parseInt(i64, text, 10) catch return st.userError("invalid JSON number", .{});
                return .{ .int = n };
            },
        }
    }

    fn parseString(self: *JsonParser, st: *Eval) EvalError![]const u8 {
        if (self.i >= self.s.len or self.s[self.i] != '"') return st.userError("expected string in JSON", .{});
        self.i += 1;
        var out = std.array_list.Managed(u8).init(self.alloc);
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            self.i += 1;
            if (c == '"') return out.toOwnedSlice();
            if (c == '\\') {
                if (self.i >= self.s.len) break;
                const e = self.s[self.i];
                self.i += 1;
                switch (e) {
                    'n' => try out.append('\n'),
                    't' => try out.append('\t'),
                    'r' => try out.append('\r'),
                    'b' => try out.append(8),
                    'f' => try out.append(12),
                    'u' => {
                        if (self.i + 4 > self.s.len) break;
                        const hex = self.s[self.i .. self.i + 4];
                        self.i += 4;
                        const cp = std.fmt.parseInt(u21, hex, 16) catch break;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch break;
                        try out.appendSlice(buf[0..n]);
                    },
                    else => try out.append(e),
                }
            } else {
                try out.append(c);
            }
        }
        return st.userError("unterminated JSON string", .{});
    }
};

// ---------------------------------------------------------------------------
// TOML (minimal parser: tables, arrays, inline tables, scalars, dates→string)
// ---------------------------------------------------------------------------

const TomlParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    line: usize = 1,

    fn err(self: *TomlParser, st: *Eval, comptime msg: []const u8) EvalError {
        return st.userError("{s} (TOML line {d})", .{ msg, self.line });
    }

    fn skipWs(self: *TomlParser) void {
        while (self.i < self.s.len) {
            switch (self.s[self.i]) {
                ' ', '\t' => self.i += 1,
                '\n' => {
                    self.i += 1;
                    self.line += 1;
                },
                '#' => {
                    while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
                },
                else => return,
            }
        }
    }

    fn peek(self: *TomlParser) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    fn parseValue(self: *TomlParser, st: *Eval) EvalError!Value {
        self.skipWs();
        const c = self.peek() orelse return self.err(st, "unexpected end of TOML");
        return switch (c) {
            '\"' => blk: {
                self.i += 1;
                var out = std.array_list.Managed(u8).init(self.alloc);
                while (self.i < self.s.len and self.s[self.i] != '"') {
                    if (self.s[self.i] == '\\' and self.i + 1 < self.s.len) {
                        const e = self.s[self.i + 1];
                        self.i += 2;
                        try out.append(switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '"' => '"',
                            '\\' => '\\',
                            else => e,
                        });
                    } else {
                        try out.append(self.s[self.i]);
                        self.i += 1;
                    }
                }
                self.i += 1;
                break :blk st.mkString(try self.alloc.dupe(u8, out.items), &.{});
            },
            '[' => blk: {
                self.i += 1;
                var elems = std.array_list.Managed(*Value).init(self.alloc);
                while (true) {
                    self.skipWs();
                    if (self.peek() == null or self.peek().? == ']') {
                        self.i += 1;
                        break;
                    }
                    const v = try self.parseValue(st);
                    const p = try self.alloc.create(Value);
                    p.* = v;
                    try elems.append(p);
                    self.skipWs();
                    if (self.peek() == ',') self.i += 1;
                }
                break :blk .{ .list = elems.items };
            },
            '{' => blk: {
                self.i += 1;
                var items = std.array_list.Managed(value.Item).init(self.alloc);
                while (true) {
                    self.skipWs();
                    if (self.peek() == null or self.peek().? == '}') {
                        self.i += 1;
                        break;
                    }
                    const name = try self.parseKey(st);
                    self.skipWs();
                    if (self.peek() != '=') return self.err(st, "expected '=' in inline table");
                    self.i += 1;
                    const v = try self.parseValue(st);
                    const p = try self.alloc.create(Value);
                    p.* = v;
                    try items.append(.{ .name = name, .value = p });
                    self.skipWs();
                    if (self.peek() == ',') self.i += 1;
                }
                break :blk st.mkAttrs(items.items);
            },
            't' => blk: {
                if (self.s.len >= self.i + 4 and std.mem.eql(u8, self.s[self.i .. self.i + 4], "true")) {
                    self.i += 4;
                    break :blk .{ .bool_ = true };
                }
                return self.err(st, "invalid TOML value");
            },
            'f' => blk: {
                if (self.s.len >= self.i + 5 and std.mem.eql(u8, self.s[self.i .. self.i + 5], "false")) {
                    self.i += 5;
                    break :blk .{ .bool_ = false };
                }
                return self.err(st, "invalid TOML value");
            },
            else => blk: {
                // number or date (dates become strings, like Nix)
                const start = self.i;
                while (self.i < self.s.len and self.s[self.i] != '\n' and self.s[self.i] != ',' and self.s[self.i] != ']' and self.s[self.i] != '}' and self.s[self.i] != '#') self.i += 1;
                const text = std.mem.trim(u8, self.s[start..self.i], " ");
                if (text.len == 0) return self.err(st, "invalid TOML value");
                if (std.mem.indexOfAny(u8, text, ":-") != null and text.len >= 8 and text[4] == '-') {
                    // Nix does not support dates/times in TOML
                    return self.err(st, "Dates and times are not supported");
                }
                if (std.mem.indexOfScalar(u8, text, '.') != null or std.mem.indexOfAny(u8, text, "eE") != null) {
                    const f = std.fmt.parseFloat(f64, text) catch return self.err(st, "invalid TOML number");
                    break :blk .{ .float = f };
                }
                const n = std.fmt.parseInt(i64, text, 10) catch return self.err(st, "invalid TOML integer");
                break :blk .{ .int = n };
            },
        };
    }

    fn parseKey(self: *TomlParser, st: *Eval) EvalError![]const u8 {
        const start = self.i;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_' or self.s[self.i] == '-')) self.i += 1;
        if (self.i == start) return self.err(st, "expected key");
        return self.s[start..self.i];
    }

    const Entry = struct {
        path: []const []const u8,
        key: []const u8,
        value: Value,
    };

    fn parseInto(self: *TomlParser, st: *Eval, out: *std.array_list.Managed(value.Item)) EvalError!void {
        var table_path = std.array_list.Managed([]const u8).init(self.alloc);
        var entries = std.array_list.Managed(Entry).init(self.alloc);
        while (true) {
            self.skipWs();
            if (self.i >= self.s.len) break;
            if (self.peek().? == '[') {
                self.i += 1;
                table_path.clearRetainingCapacity();
                while (true) {
                    const k = try self.parseKey(st);
                    try table_path.append(k);
                    self.skipWs();
                    if (self.peek() == ']') {
                        self.i += 1;
                        break;
                    }
                    if (self.peek() == '.') self.i += 1;
                }
                self.skipWs();
                if (self.i < self.s.len and self.s[self.i] == '\n') {
                    self.i += 1;
                    self.line += 1;
                }
                continue;
            }
            const key = try self.parseKey(st);
            self.skipWs();
            if (self.peek() != '=') return self.err(st, "expected '=' after key");
            self.i += 1;
            const v = try self.parseValue(st);
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == '\n') {
                self.i += 1;
                self.line += 1;
            }
            try entries.append(.{ .path = table_path.items, .key = key, .value = v });
        }
        // Build the nested attr tree from the collected entries.
        try buildTable(st, out, entries.items, 0);
    }

    fn buildTable(
        st: *Eval,
        items: *std.array_list.Managed(value.Item),
        entries: []const Entry,
        depth: usize,
    ) EvalError!void {
        var i: usize = 0;
        while (i < entries.len) {
            const e = entries[i];
            if (e.path.len == depth) {
                const p = try st.alloc.create(Value);
                p.* = e.value;
                try items.append(.{ .name = e.key, .value = p });
                i += 1;
                continue;
            }
            // group entries sharing this path prefix
            const seg = e.path[depth];
            const start = i;
            while (i < entries.len and entries[i].path.len > depth and std.mem.eql(u8, entries[i].path[depth], seg)) i += 1;
            const sub_items = try st.alloc.create(std.array_list.Managed(value.Item));
            sub_items.* = std.array_list.Managed(value.Item).init(st.alloc);
            try buildTable(st, sub_items, entries[start..i], depth + 1);
            const sub = try st.alloc.create(Value);
            sub.* = try st.mkAttrs(sub_items.items);
            try items.append(.{ .name = seg, .value = sub });
        }
    }
};

fn primFromTOML(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    const s = try forceStringNoCtx(st, args[0], "while evaluating the argument to builtins.fromTOML");
    var p = TomlParser{ .alloc = st.alloc, .s = s };
    var items = std.array_list.Managed(value.Item).init(st.alloc);
    try p.parseInto(st, &items);
    return st.mkAttrs(items.items);
}

fn xmlEscape(st: *Eval, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&<>\"'") == null) return s;
    var out = std.array_list.Managed(u8).init(st.alloc);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice("&amp;"),
            '<' => try out.appendSlice("&lt;"),
            '>' => try out.appendSlice("&gt;"),
            '"' => try out.appendSlice("&quot;"),
            '\'' => try out.appendSlice("&apos;"),
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

fn xmlIndent(_: *Eval, w: *std.array_list.Managed(u8), level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) try w.appendSlice("  ");
}

fn xmlWrite(st: *Eval, v: *Value, w: *std.array_list.Managed(u8), level: usize) EvalError!void {
    try st.force(v);
    switch (v.*) {
        .int => |i| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<int value=\"{d}\" />", .{i})),
        .float => |f| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<float value=\"{d}\" />", .{f})),
        .bool_ => |b| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<bool value=\"{s}\" />", .{if (b) "true" else "false"})),
        .null_ => try w.appendSlice("<null />"),
        .string => |s2| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<string value=\"{s}\" />", .{try xmlEscape(st, s2.s)})),
        .path => |p| try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<path value=\"{s}\" />", .{try xmlEscape(st, p.p)})),
        .list => |l| {
            try w.appendSlice("<list>\n");
            for (l) |e| {
                try xmlIndent(st, w, level + 1);
                try xmlWrite(st, e, w, level + 1);
                try w.append('\n');
            }
            try xmlIndent(st, w, level);
            try w.appendSlice("</list>");
        },
        .attrs => |a| {
            try w.appendSlice("<attrs>\n");
            for (a.items) |it| {
                try xmlIndent(st, w, level + 1);
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<attr name=\"{s}\">\n", .{try xmlEscape(st, it.name)}));
                try xmlIndent(st, w, level + 2);
                try xmlWrite(st, it.value, w, level + 2);
                try w.append('\n');
                try xmlIndent(st, w, level + 1);
                try w.appendSlice("</attr>\n");
            }
            try xmlIndent(st, w, level);
            try w.appendSlice("</attrs>");
        },
        .lambda => |l| {
            try w.appendSlice("<function>");
            if (l.params.formals) |f| {
                try w.append('\n');
                for (f.formals) |f2| {
                    try xmlIndent(st, w, level + 1);
                    try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<varpat name=\"{s}\" />\n", .{try xmlEscape(st, f2.name)}));
                }
                try xmlIndent(st, w, level);
            } else if (l.params.arg) |a| {
                try w.append('\n');
                try xmlIndent(st, w, level + 1);
                try w.appendSlice(try std.fmt.allocPrint(st.alloc, "<varpat name=\"{s}\" />\n", .{try xmlEscape(st, a)}));
                try xmlIndent(st, w, level);
            }
            try w.appendSlice("</function>");
        },
        else => return st.userError("cannot convert {s} to XML", .{eval.EvalState.showType(v.*)}),
    }
}

fn primToXML(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;
    var w = std.array_list.Managed(u8).init(st.alloc);
    try w.appendSlice("<?xml version='1.0' encoding='utf-8'?>\n<expr>\n  ");
    try xmlWrite(st, args[0], &w, 1);
    try w.appendSlice("\n</expr>\n");
    return st.mkString(try st.alloc.dupe(u8, w.items), &.{});
}

fn primFromJSON(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const s = try forceStringNoCtx(st, args[0], "");
    var p = JsonParser{ .alloc = st.alloc, .s = s };
    const v = try p.parseValue(st);
    p.skipWs();
    if (p.i != s.len) return st.userError("trailing characters after JSON value", .{});
    return v;
}

// ---------------------------------------------------------------------------
// Minimal regex engine (literals, ., [...], [^...], groups, *, +, ?, |, ^, $)
// ---------------------------------------------------------------------------

const RNode = union(enum) {
    ch: u8,
    any,
    class: Class,
    seq: []const RNode,
    alt: []const RNode,
    repeat: Repeat,
    group: Group,
};

const Repeat = struct {
    min: usize,
    max: usize, // usize max = unbounded
    lazy: bool,
    child: *const RNode,
};

const Group = struct {
    idx: usize,
    inner: *const RNode,
};

const Class = struct {
    negated: bool,
    chars: []const u8, // literal chars
    ranges: []const [2]u8,
    any_char: bool, // '.' inside class
    posix: []const []const u8, // posix class names, e.g. "alnum"
};

const Regex = struct {
    node: RNode,
    anchored: bool,
    ngroups: usize,
};

fn regexParse(st: *Eval, pat: []const u8) EvalError!Regex {
    var p = RegexParser{ .alloc = st.alloc, .s = pat };
    const anchored = p.i < p.s.len and p.s[p.i] == '^';
    if (anchored) p.i += 1;
    const node = try p.parseAlt(st);
    return .{ .node = node, .anchored = anchored, .ngroups = p.ngroups };
}

const RegexParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    ngroups: usize = 0,

    fn parseAlt(self: *RegexParser, st: *Eval) EvalError!RNode {
        var alts = std.array_list.Managed(RNode).init(self.alloc);
        try alts.append(try self.parseSeq(st));
        while (self.i < self.s.len and self.s[self.i] == '|') {
            self.i += 1;
            try alts.append(try self.parseSeq(st));
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .alt = alts.items };
    }

    fn parseSeq(self: *RegexParser, st: *Eval) EvalError!RNode {
        var seq = std.array_list.Managed(RNode).init(self.alloc);
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == '|' or c == ')') break;
            var node = try self.parseAtom(st);
            // postfix quantifiers: * + ? {n,m}, each optionally lazy (*?)
            if (self.i < self.s.len) {
                var min: ?usize = null;
                var max: usize = std.math.maxInt(usize);
                var lazy = false;
                switch (self.s[self.i]) {
                    '*' => {
                        self.i += 1;
                        min = 0;
                    },
                    '+' => {
                        self.i += 1;
                        min = 1;
                    },
                    '?' => {
                        self.i += 1;
                        min = 0;
                        max = 1;
                    },
                    '{' => {
                        const save = self.i;
                        if (self.parseRepeatBounds()) |b| {
                            min = b.min;
                            max = b.max;
                        } else {
                            self.i = save; // not a repeat: literal '{'
                        }
                    },
                    else => {},
                }
                if (min != null) {
                    if (self.i < self.s.len and self.s[self.i] == '?') {
                        self.i += 1;
                        lazy = true;
                    }
                    const p = try self.alloc.create(RNode);
                    p.* = node;
                    node = .{ .repeat = .{ .min = min.?, .max = max, .lazy = lazy, .child = p } };
                }
            }
            try seq.append(node);
        }
        if (seq.items.len == 1) return seq.items[0];
        return .{ .seq = seq.items };
    }

    /// Parse `{n}`, `{n,}`, `{n,m}`.  Returns null if it doesn't look like a
    /// bound (in which case `{` is a literal).
    fn parseRepeatBounds(self: *RegexParser) ?struct { min: usize, max: usize } {
        var j = self.i + 1;
        const digits_start = j;
        while (j < self.s.len and self.s[j] >= '0' and self.s[j] <= '9') j += 1;
        if (j == digits_start) return null;
        const n1 = std.fmt.parseInt(usize, self.s[digits_start..j], 10) catch return null;
        if (j < self.s.len and self.s[j] == '}') {
            self.i = j + 1;
            return .{ .min = n1, .max = n1 };
        }
        if (j >= self.s.len or self.s[j] != ',') return null;
        j += 1;
        const d2 = j;
        while (j < self.s.len and self.s[j] >= '0' and self.s[j] <= '9') j += 1;
        if (j < self.s.len and self.s[j] == '}') {
            self.i = j + 1;
            if (j == d2) return .{ .min = n1, .max = std.math.maxInt(usize) };
            const n2 = std.fmt.parseInt(usize, self.s[d2..j], 10) catch return null;
            return .{ .min = n1, .max = n2 };
        }
        return null;
    }

    fn parseAtom(self: *RegexParser, st: *Eval) EvalError!RNode {
        if (self.i >= self.s.len) return st.userError("unexpected end of regex", .{});
        const c = self.s[self.i];
        switch (c) {
            '.' => {
                self.i += 1;
                return .any;
            },
            '\\' => {
                if (self.i + 1 >= self.s.len) return st.userError("trailing backslash in regex", .{});
                const e = self.s[self.i + 1];
                self.i += 2;
                return .{ .ch = e };
            },
            '[' => {
                self.i += 1;
                var negated = false;
                if (self.i < self.s.len and self.s[self.i] == '^') {
                    negated = true;
                    self.i += 1;
                }
                var chars = std.array_list.Managed(u8).init(self.alloc);
                var ranges = std.array_list.Managed([2]u8).init(self.alloc);
                var posix = std.array_list.Managed([]const u8).init(self.alloc);
                var any_char = false;
                while (self.i < self.s.len and self.s[self.i] != ']') {
                    // POSIX class: [:name:]
                    if (self.i + 2 < self.s.len and self.s[self.i] == '[' and self.s[self.i + 1] == ':') {
                        const name_start = self.i + 2;
                        var j = name_start;
                        while (j + 1 < self.s.len and !(self.s[j] == ':' and self.s[j + 1] == ']')) j += 1;
                        if (j + 1 < self.s.len) {
                            try posix.append(self.s[name_start..j]);
                            self.i = j + 2;
                            continue;
                        }
                    }
                    var lo = self.s[self.i];
                    self.i += 1;
                    if (lo == '\\' and self.i < self.s.len) {
                        lo = self.s[self.i];
                        self.i += 1;
                    }
                    if (self.i + 1 < self.s.len and self.s[self.i] == '-' and self.s[self.i + 1] != ']') {
                        self.i += 1;
                        var hi = self.s[self.i];
                        self.i += 1;
                        if (hi == '\\' and self.i < self.s.len) {
                            hi = self.s[self.i];
                            self.i += 1;
                        }
                        try ranges.append(.{ lo, hi });
                    } else {
                        if (lo == '.') {
                            any_char = true;
                        } else {
                            try chars.append(lo);
                        }
                    }
                }
                if (self.i < self.s.len and self.s[self.i] == ']') self.i += 1;
                return .{ .class = .{ .negated = negated, .chars = chars.items, .ranges = ranges.items, .any_char = any_char, .posix = posix.items } };
            },
            '(' => {
                self.i += 1;
                const idx = self.ngroups;
                self.ngroups += 1;
                const inner = try self.parseAlt(st);
                if (self.i < self.s.len and self.s[self.i] == ')') self.i += 1;
                const p = try self.alloc.create(RNode);
                p.* = inner;
                return .{ .group = .{ .idx = idx, .inner = p } };
            },
            '^' => {
                self.i += 1;
                return .{ .ch = 0 }; // only valid at start; handled via anchored
            },
            '$' => {
                self.i += 1;
                return .{ .ch = 0 };
            },
            else => {
                self.i += 1;
                return .{ .ch = c };
            },
        }
    }
};

fn posixClassMatch(name: []const u8, c: u8) bool {
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(c);
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(c);
    if (std.mem.eql(u8, name, "punct")) return std.ascii.isPunctuation(c);
    if (std.mem.eql(u8, name, "cntrl")) return std.ascii.isControl(c);
    if (std.mem.eql(u8, name, "graph")) return c > 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "print")) return std.ascii.isPrint(c);
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    return false;
}

fn classMatch(cls: Class, c: u8) bool {
    var m = false;
    for (cls.chars) |ch| {
        if (ch == c) {
            m = true;
            break;
        }
    }
    if (!m) {
        for (cls.ranges) |r| {
            if (c >= r[0] and c <= r[1]) {
                m = true;
                break;
            }
        }
    }
    if (!m) {
        for (cls.posix) |name| {
            if (posixClassMatch(name, c)) {
                m = true;
                break;
            }
        }
    }
    if (!m and cls.any_char) m = true;
    return if (cls.negated) !m else m;
}

// --- Matcher --------------------------------------------------------------
// Backtracking matcher that collects, for a node at `pos`, every possible end
// position (in priority order: greedy = long first, lazy = short first) with a
// snapshot of the capture groups.  The caller picks the first accepted end.

const MatchEnd = struct {
    pos: usize,
    caps: []?[2]usize,
};

const MatchCtx = struct {
    st: *Eval,
    s: []const u8,
    ends: *std.array_list.Managed(MatchEnd),
};

fn matchAddEnd(ctx: *MatchCtx, pos: usize, caps: []?[2]usize) EvalError!void {
    const copy = try ctx.st.alloc.dupe(?[2]usize, caps);
    try ctx.ends.append(.{ .pos = pos, .caps = copy });
}

fn matchNode(ctx: *MatchCtx, node: *const RNode, pos: usize, caps: []?[2]usize) EvalError!void {
    if (ctx.ends.items.len > 50000) return;
    switch (node.*) {
        .ch => |c| {
            if (c == 0) {
                try matchAddEnd(ctx, pos, caps);
                return;
            }
            if (pos < ctx.s.len and ctx.s[pos] == c) try matchAddEnd(ctx, pos + 1, caps);
        },
        .any => {
            // Nix's regex (`std::regex`) lets `.` match any character.
            if (pos < ctx.s.len) try matchAddEnd(ctx, pos + 1, caps);
        },
        .class => |cls| {
            if (pos < ctx.s.len and classMatch(cls, ctx.s[pos])) try matchAddEnd(ctx, pos + 1, caps);
        },
        .seq => |seq| try matchSeq(ctx, seq, 0, pos, caps),
        .alt => |alts| {
            for (alts) |*item| {
                const before = ctx.ends.items.len;
                try matchNode(ctx, item, pos, caps);
                const produced = try ctx.st.alloc.dupe(MatchEnd, ctx.ends.items[before..]);
                ctx.ends.shrinkRetainingCapacity(before);
                for (produced) |e| try ctx.ends.append(e);
            }
        },
        .group => |g| {
            const before = ctx.ends.items.len;
            try matchNode(ctx, g.inner, pos, caps);
            const produced = try ctx.st.alloc.dupe(MatchEnd, ctx.ends.items[before..]);
            ctx.ends.shrinkRetainingCapacity(before);
            for (produced) |e| {
                const caps2 = try ctx.st.alloc.dupe(?[2]usize, e.caps);
                caps2[g.idx] = .{ pos, e.pos };
                try ctx.ends.append(.{ .pos = e.pos, .caps = caps2 });
            }
        },
        .repeat => |r| try matchRepeat(ctx, r, pos, caps),
    }
}

fn matchSeq(ctx: *MatchCtx, seq: []const RNode, i: usize, pos: usize, caps: []?[2]usize) EvalError!void {
    if (i >= seq.len) {
        try matchAddEnd(ctx, pos, caps);
        return;
    }
    const before = ctx.ends.items.len;
    try matchNode(ctx, &seq[i], pos, caps);
    // Copy the produced ends: the buffer reallocates as we recurse.
    const produced = try ctx.st.alloc.dupe(MatchEnd, ctx.ends.items[before..]);
    ctx.ends.shrinkRetainingCapacity(before);
    for (produced) |e| {
        try matchSeq(ctx, seq, i + 1, e.pos, e.caps);
    }
}

/// Match a repeat `{min,max}`: try k iterations for each k in range.
/// Greedy tries the most iterations first; lazy tries the fewest first.
fn matchRepeat(ctx: *MatchCtx, r: Repeat, pos: usize, caps: []?[2]usize) EvalError!void {
    var levels = std.array_list.Managed(std.array_list.Managed(MatchEnd)).init(ctx.st.alloc);
    var level0 = std.array_list.Managed(MatchEnd).init(ctx.st.alloc);
    try level0.append(.{ .pos = pos, .caps = caps });
    try levels.append(level0);
    var k: usize = 0;
    while (k < r.max) {
        const prev = levels.items[k];
        if (prev.items.len == 0) break;
        var next = std.array_list.Managed(MatchEnd).init(ctx.st.alloc);
        for (prev.items) |e| {
            const before = ctx.ends.items.len;
            try matchNode(ctx, r.child, e.pos, e.caps);
            const produced = try ctx.st.alloc.dupe(MatchEnd, ctx.ends.items[before..]);
            ctx.ends.shrinkRetainingCapacity(before);
            for (produced) |p2| try next.append(p2);
        }
        try levels.append(next);
        k += 1;
    }
    if (r.lazy) {
        var kk: usize = r.min;
        while (kk < levels.items.len) : (kk += 1) {
            for (levels.items[kk].items) |e| try ctx.ends.append(e);
        }
    } else {
        var kk = levels.items.len;
        while (kk > r.min) {
            kk -= 1;
            for (levels.items[kk].items) |e| try ctx.ends.append(e);
        }
    }
}

/// Search: try every start position, run the matcher, pick the first end.
/// `full` = the match must consume the whole string (builtins.match).
fn regexFindMatch(st: *Eval, re: *const Regex, s: []const u8, start: usize, full: bool) EvalError!?struct { mstart: usize, end: usize, caps: []?[2]usize } {
    var search = start;
    while (search <= s.len) {
        var ends = std.array_list.Managed(MatchEnd).init(st.alloc);
        var ctx = MatchCtx{ .st = st, .s = s, .ends = &ends };
        const caps = try st.alloc.alloc(?[2]usize, re.ngroups);
        @memset(caps, null);
        try matchNode(&ctx, &re.node, search, caps);
        for (ends.items) |e| {
            if (!full or e.pos == s.len) {
                return .{ .mstart = search, .end = e.pos, .caps = e.caps };
            }
        }
        search += 1;
    }
    return null;
}

fn regexMatch(st: *Eval, pat: []const u8, s: []const u8) EvalError!Value {
    const re = try regexParse(st, pat);
    const m = (try regexFindMatch(st, &re, s, 0, true)) orelse return .null_;
    const out = try st.alloc.alloc(*Value, re.ngroups);
    for (0..re.ngroups) |i| {
        const v = try st.alloc.create(Value);
        if (m.caps[i]) |span| {
            v.* = st.mkString(s[span[0]..span[1]], &.{});
        } else {
            v.* = .null_;
        }
        out[i] = v;
    }
    return .{ .list = out };
}

fn regexSplit(st: *Eval, pat: []const u8, s: []const u8) EvalError!Value {
    // Mirrors Nix's `prim_split` (std::regex_iterator semantics): each match
    // contributes its prefix text and its capture groups; the suffix of the
    // last match is appended even when empty.
    const re = try regexParse(st, pat);
    var out = std.array_list.Managed(*Value).init(st.alloc);
    var pos: usize = 0;
    var prev_end: usize = 0;
    var last_end: usize = 0;
    var found = false;
    while (true) {
        const m = (try regexFindMatch(st, &re, s, pos, false)) orelse break;
        found = true;
        const v = try st.alloc.create(Value);
        v.* = st.mkString(s[prev_end..m.mstart], &.{});
        try out.append(v);
        const caps = try st.alloc.alloc(*Value, re.ngroups);
        for (0..re.ngroups) |i| {
            const cv = try st.alloc.create(Value);
            if (m.caps[i]) |span| {
                cv.* = st.mkString(s[span[0]..span[1]], &.{});
            } else {
                cv.* = .null_;
            }
            caps[i] = cv;
        }
        const mv = try st.alloc.create(Value);
        mv.* = .{ .list = caps };
        try out.append(mv);
        last_end = m.end;
        prev_end = m.end;
        // std::regex_iterator advances one char after an empty match.
        pos = if (m.end == m.mstart) m.mstart + 1 else m.end;
    }
    if (!found) {
        const whole = try st.alloc.create(Value);
        whole.* = st.mkString(s, &.{});
        try out.append(whole);
        return .{ .list = out.items };
    }
    const suffix = try st.alloc.create(Value);
    suffix.* = st.mkString(s[last_end..], &.{});
    try out.append(suffix);
    return .{ .list = out.items };
}
