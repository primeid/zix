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
    return st.coerceToString(v, ctx, copy, what);
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
            const b = try st2.alloc.create(value.Builtin);
            b.* = .{ .name = name, .arity = arity, .f = f };
            const v = try st2.alloc.create(Value);
            v.* = .{ .builtin = b.* };
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
    try B.add(&items, st, "bitNot", 1, primBitNot);
    try B.add(&items, st, "toString", 1, primToString);
    try B.add(&items, st, "toJSON", 1, primToJSON);
    try B.add(&items, st, "fromJSON", 1, primFromJSON);
    try B.add(&items, st, "map", 2, primMap);
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
    try B.add(&items, st, "take", 2, primTake);
    try B.add(&items, st, "drop", 2, primDrop);
    try B.add(&items, st, "reverseList", 1, primReverseList);
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
    try B.add(&items, st, "toUpper", 1, primToUpper);
    try B.add(&items, st, "toLower", 1, primToLower);
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
    try B.add(&items, st, "derivationStrict", 1, primDerivationStrict);
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
    return st.userError("abort: {s}", .{msg});
}

fn primThrow(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const msg = try forceStringNoCtx(st, args[0], "while evaluating the argument to builtins.throw");
    return st.userError("throw: {s}", .{msg});
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
    const s = try st.coerceToString(&v, &ctx, false, "while evaluating the argument to builtins.toString");
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
    const acc: *Value = args[1];
    const list = try forceList(st, args[2], "");
    for (list) |elem| {
        var r = try st.apply(fun, acc, pos);
        r = try st.apply(r, elem, pos);
        acc.* = r;
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
        const pair = ctx.st.alloc.create(Value) catch return false;
        pair.* = .{ .list = &.{ a, b } };
        var r = ctx.st.apply(ctx.fun, pair, 0) catch return false;
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
        for (items.items) |it| {
            if (std.mem.eql(u8, it.name, name)) return st.userError("duplicate attribute '{s}' in 'listToAttrs'", .{name});
        }
        try items.append(.{ .name = name, .value = val_v });
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
        if (l.* != .list) return st.userError("'zipAttrsWith': element is not a list", .{});
        for (l.list) |e| {
            var ev = e.*;
            try st.force(&ev);
            if (ev != .attrs) return st.userError("'zipAttrsWith': element is not a set", .{});
            for (ev.attrs.items) |it| {
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
    }
    const items = try st.alloc.alloc(value.Item, keys.items.len);
    for (keys.items, 0..) |k, i| {
        const v = try st.alloc.create(Value);
        v.* = .{ .list = vals.items[i].items };
        items[i] = .{ .name = k, .value = v };
        const r = try st.apply(fun, v, pos);
        items[i].value = try st.alloc.create(Value);
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
    if (start < 0 or len < 0) return st.userError("negative start position or length in 'substring'", .{});
    const s_i: usize = @intCast(start);
    const l_i: usize = @intCast(len);
    if (s_i >= s.len) return st.mkString("", &.{});
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
        const s = try st.coerceToString(&ev, &ctx, false, "while evaluating an element");
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

    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    const s = try forceStringWithCtx(st, args[0], &ctx, false, "while evaluating the argument to builtins.dirOf");
    const dir = std.fs.path.dirname(s) orelse ".";
    return st.mkString(dir, ctx.items);
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

fn primPath(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const a = try forceAttrs(st, args[0], "while evaluating the argument to builtins.path");
    const path_v = a.find("path") orelse return st.userError("attribute 'path' missing", .{});
    var pv = path_v.*;
    try st.force(&pv);
    const p: []const u8 = switch (pv) {
        .path => |p| p.p,
        .string => |s| s.s,
        else => return st.userError("'path' attribute is not a path", .{}),
    };
    const sp = st.copyPathToStore(p) catch |e| {
        return st.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
    };
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
    if (!std.mem.eql(u8, algo, "sha256")) {
        return st.userError("unknown hash algorithm '{s}'", .{algo});
    }
    const h = nixhash.Hash.of(s);
    return st.mkString(try h.base16(st.alloc), &.{});
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
    var ctx = std.array_list.Managed(value.CtxElem).init(st.alloc);
    try ctx.append(.{ .kind = .opaq, .path = p });
    return st.mkString(p, ctx.items);
}

fn primGetEnv(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const name = try forceStringNoCtx(st, args[0], "");
    const val = if (st.environ) |env| env.get(name) orelse "" else "";
    return st.mkString(val, &.{});
}

fn primCurrentSystem(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = args;
    _ = pos;

    const b = @import("builtin");
    return st.mkString(@tagName(b. target.cpu.arch) ++ "-" ++ @tagName(b.target.os.tag), &.{});
}

fn primCurrentTime(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = st;
    _ = args;
    _ = pos;

    // epoch seconds (Linux)
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return .{ .int = @intCast(ts.sec) };
}

fn primNixVersion(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = args;
    _ = pos;

    return st.mkString("2.34.7-zix", &.{});
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

    _ = st;
    _ = args;
    return error.Unsupported;
}

fn primTryEval(st: *Eval, args: []const *Value, pos: usize) EvalError!Value {
    _ = pos;

    const success = try st.alloc.create(Value);
    const valv = try st.alloc.create(Value);
    if (st.tryEval(args[0])) |val| {
        success.* = .{ .bool_ = true };
        valv.* = val;
    } else |_| {
        success.* = .{ .bool_ = false };
        valv.* = .null_;
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
        const key = try st.coerceToPlainString(&kv, "while evaluating the 'key' attribute");
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

    var env = std.array_list.Managed(drvmod.EnvPair).init(st.alloc);
    var args_list = std.array_list.Managed([]const u8).init(st.alloc);
    var context = std.array_list.Managed(value.CtxElem).init(st.alloc);
    var content_addressed = false;
    var is_impure = false;
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
                const s = try st.coerceToString(&ev, &context, true, "while evaluating an element of the argument list");
                try args_list.append(s);
            }
            continue;
        }
        // default: environment variable (coerced with store copying)
        const s = try st.coerceToString(&v, &context, true, "while evaluating a derivation attribute");
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
        if (std.mem.eql(u8, it.name, "outputs")) {
            outputs.clearRetainingCapacity();
            var it_tok = std.mem.tokenizeAny(u8, s, " \t\n");
            while (it_tok.next()) |o| try outputs.append(o);
            if (outputs.items.len == 0) return st.userError("derivation cannot have an empty set of outputs", .{});
        }
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
        // fixed-output derivation
        if (outputs.items.len != 1 or !std.mem.eql(u8, outputs.items[0], "out")) {
            return st.userError("multiple outputs are not supported in fixed-output derivations", .{});
        }
        if (!std.mem.eql(u8, output_hash_algo, "sha256")) {
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
    if (output_hash == null and !content_addressed and !is_impure) {
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
    const drv_path = st.store.writeText(drv_file_name, contents, refs.items) catch |e| {
        return st.userError("cannot write derivation to store: {s}", .{@errorName(e)});
    };

    // Result: { drvPath, <outputs> }
    const n = drv_outputs.items.len + 1;
    const items = try st.alloc.alloc(value.Item, n);
    const drvp_v = try st.alloc.create(Value);
    drvp_v.* = st.mkString(drv_path, &.{.{ .kind = .drv_deep, .path = drv_path }});
    items[0] = .{ .name = "drvPath", .value = drvp_v };
    for (drv_outputs.items, 0..) |o, i| {
        const v = try st.alloc.create(Value);
        v.* = st.mkString(o.path, &.{.{ .kind = .drv_out, .path = drv_path, .output = o.name }});
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

fn jsonWrite(st: *Eval, v: *Value, w: *std.array_list.Managed(u8)) EvalError!void {
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
    star: *const RNode,
    plus: *const RNode,
    opt: *const RNode,
    group: *const RNode,
};

const Class = struct {
    negated: bool,
    chars: []const u8, // literal chars
    ranges: []const [2]u8,
    any_char: bool, // '.' inside class
};

const Regex = struct {
    node: RNode,
    anchored: bool,
};

fn regexParse(st: *Eval, pat: []const u8) EvalError!Regex {
    var p = RegexParser{ .alloc = st.alloc, .s = pat };
    const anchored = p.i < p.s.len and p.s[p.i] == '^';
    if (anchored) p.i += 1;
    const node = try p.parseAlt(st);
    return .{ .node = node, .anchored = anchored };
}

const RegexParser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

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
            // postfix
            if (self.i < self.s.len) {
                switch (self.s[self.i]) {
                    '*' => {
                        self.i += 1;
                        const p = try self.alloc.create(RNode);
                        p.* = node;
                        node = .{ .star = p };
                    },
                    '+' => {
                        self.i += 1;
                        const p = try self.alloc.create(RNode);
                        p.* = node;
                        node = .{ .plus = p };
                    },
                    '?' => {
                        self.i += 1;
                        const p = try self.alloc.create(RNode);
                        p.* = node;
                        node = .{ .opt = p };
                    },
                    else => {},
                }
            }
            try seq.append(node);
        }
        if (seq.items.len == 1) return seq.items[0];
        return .{ .seq = seq.items };
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
                var any_char = false;
                while (self.i < self.s.len and self.s[self.i] != ']') {
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
                return .{ .class = .{ .negated = negated, .chars = chars.items, .ranges = ranges.items, .any_char = any_char } };
            },
            '(' => {
                self.i += 1;
                const inner = try self.parseAlt(st);
                if (self.i < self.s.len and self.s[self.i] == ')') self.i += 1;
                const p = try self.alloc.create(RNode);
                p.* = inner;
                return .{ .group = p };
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
    if (!m and cls.any_char and c != '\n') m = true;
    return if (cls.negated) !m else m;
}

fn regexMatchAt(node: *const RNode, s: []const u8, pos: usize, captures: *std.array_list.Managed([]const u8)) EvalError!?usize {
    switch (node.*) {
        .ch => |c| {
            if (c == 0) return pos; // dummy anchor marker
            if (pos < s.len and s[pos] == c) return pos + 1;
            return null;
        },
        .any => {
            if (pos < s.len and s[pos] != '\n') return pos + 1;
            return null;
        },
        .class => |cls| {
            if (pos < s.len and classMatch(cls, s[pos])) return pos + 1;
            return null;
        },
        .seq => |seq| {
            var p = pos;
            for (seq) |*item| {
                const np = (try regexMatchAt(item, s, p, captures)) orelse return null;
                p = np;
            }
            return p;
        },
        .alt => |alts| {
            for (alts) |*item| {
                const save_len = captures.items.len;
                if (try regexMatchAt(item, s, pos, captures)) |np| return np;
                captures.shrinkRetainingCapacity(save_len);
            }
            return null;
        },
        .group => |inner| {
            const gstart = captures.items.len;
            try captures.append(s[pos..pos]);
            const np = (try regexMatchAt(inner, s, pos, captures)) orelse return null;
            captures.items[gstart] = s[pos..np];
            return np;
        },
        .star => |inner| {
            var p = pos;
            while (true) {
                const save_len = captures.items.len;
                const np = (try regexMatchAt(inner, s, p, captures)) orelse break;
                _ = save_len;
                if (np == p) break;
                p = np;
            }
            return p;
        },
        .plus => |inner| {
            const save = captures.items.len;
            _ = save;
            const np = (try regexMatchAt(inner, s, pos, captures)) orelse return null;
            var p = np;
            while (true) {
                const np2 = (try regexMatchAt(inner, s, p, captures)) orelse break;
                if (np2 == p) break;
                p = np2;
            }
            return p;
        },
        .opt => |inner| {
            const save_len = captures.items.len;
            if (try regexMatchAt(inner, s, pos, captures)) |np| return np;
            captures.shrinkRetainingCapacity(save_len);
            return pos;
        },
    }
}

fn regexMatch(st: *Eval, pat: []const u8, s: []const u8) EvalError!Value {

    const re = try regexParse(st, pat);
    // full-match semantics (anchored)
    var captures = std.array_list.Managed([]const u8).init(st.alloc);
    const end = (try regexMatchAt(&re.node, s, 0, &captures)) orelse return .null_;
    if (end != s.len) return .null_;
    const out = try st.alloc.alloc(*Value, captures.items.len);
    for (captures.items, 0..) |cap, i| {
        const v = try st.alloc.create(Value);
        v.* = st.mkString(cap, &.{});
        out[i] = v;
    }
    return .{ .list = out };
}

fn regexSplit(st: *Eval, pat: []const u8, s: []const u8) EvalError!Value {

    const re = try regexParse(st, pat);
    var out = std.array_list.Managed(*Value).init(st.alloc);
    var pos: usize = 0;
    while (pos < s.len) {
        // find next match starting at or after pos
        var mstart: ?usize = null;
        var mend: usize = 0;
        var mcap = std.array_list.Managed([]const u8).init(st.alloc);
        var search = pos;
        while (search <= s.len) {
            var captures = std.array_list.Managed([]const u8).init(st.alloc);
            if (try regexMatchAt(&re.node, s, search, &captures)) |end| {
                mstart = search;
                mend = end;
                mcap = captures;
                break;
            }
            search += 1;
        }
        if (mstart == null) break;
        // text before the match
        const v = try st.alloc.create(Value);
        v.* = st.mkString(s[pos..mstart.?], &.{});
        try out.append(v);
        // the match itself: string, or list of captures
        if (mcap.items.len > 0) {
            const caps = try st.alloc.alloc(*Value, mcap.items.len);
            for (mcap.items, 0..) |cap, i| {
                const cv = try st.alloc.create(Value);
                cv.* = st.mkString(cap, &.{});
                caps[i] = cv;
            }
            const mv = try st.alloc.create(Value);
            mv.* = .{ .list = caps };
            try out.append(mv);
        } else {
            const mv = try st.alloc.create(Value);
            mv.* = st.mkString(s[mstart.?..mend], &.{});
            try out.append(mv);
        }
        pos = mend;
    }
    const last = try st.alloc.create(Value);
    last.* = st.mkString(s[pos..], &.{});
    try out.append(last);
    return .{ .list = out.items };
}
