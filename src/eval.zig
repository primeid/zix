//! The ZIX evaluator: lazy evaluation of the Nix expression language,
//! faithful to Nix 2.34 (`eval.cc`, `eval-inline.hh`).

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const store = @import("store.zig");
const nixhash = @import("nixhash.zig");
const fsutil = @import("fsutil.zig");
const builtins = @import("builtins.zig");

pub const Value = value.Value;
pub const Attrs = value.Attrs;
pub const Env = value.Env;
pub const Item = value.Item;
pub const Var = value.Var;

pub const EvalError = error{
    OutOfMemory,
    UserError, // throw / abort / assertion failure (message in state.err_msg)
    InfiniteRecursion,
    BadType,
    NotFound,
    InvalidName,
    IoError,
    StoreError,
    ParseError,
    InvalidInteger,
    DuplicateAttr,
    DynamicAttrsInLet,
    Unsupported,
} || std.mem.Allocator.Error;

pub const NixPathEntry = struct {
    prefix: []const u8, // may be empty for bare entries (prefix = basename)
    path: []const u8,
};

pub const EvalState = struct {
    alloc: std.mem.Allocator,
    store: store.Store,
    home_dir: []const u8,
    nix_path: []const NixPathEntry,
    builtins_attrs: *Attrs,
    base_env: *Env,
    /// message for UserError
    err_msg: []const u8 = "",
    /// kind of the current user error (for builtins.tryEval)
    err_kind: enum { none, assert, thrown, other } = .none,
    /// nested evaluation depth (guards against stack overflow)
    call_depth: usize = 0,
    /// position of the expression currently being evaluated (for errors)
    cur_pos: ast.Pos = .{},
    /// set when an error is in flight so the trace is kept during unwinding
    err_active: bool = false,
    /// current evaluation chain (innermost last) for cycle diagnostics
    eval_chain: std.array_list.Managed(ast.Pos) = undefined,
    /// eqValues recursion depth (for debugging deep equality comparisons)
    eq_depth: usize = 0,
    /// visited (a,b) attrset pairs during deep equality (cycle detection)
    eq_seen: std.AutoHashMap(u64, void) = undefined,
    /// JSON serialisation depth (guards against cyclic structures)
    json_depth: usize = 0,
    /// temp dir where embedded corepkgs (`nix/fetchurl.nix`) are materialised
    corepkgs_dir: []const u8 = "/tmp",
    /// error trace: innermost positions first (for Nix-style traces)
    err_trace: std.array_list.Managed(ast.Pos) = undefined,
    /// current file being evaluated (for __curPos / import paths)
    cur_file: []const u8 = "",
    /// import cache: path → parsed expr
    import_cache: std.StringHashMap(*ast.Expr),
    /// cache of store-copied paths: source path → store path
    src_to_store: std.StringHashMap([]const u8),
    /// parse cache for builtins.derivation wrapper
    derivation_wrapper: ?*value.Lambda = null,
    /// process environment (from std.process.Init), for builtins.getEnv
    environ: ?*const std.process.Environ.Map = null,

    pub fn init(alloc: std.mem.Allocator, store_dir: []const u8, read_only: bool, home_dir: []const u8) !*EvalState {
        const st = try alloc.create(EvalState);
        st.* = .{
            .alloc = alloc,
            .store = store.Store.init(alloc, store_dir, read_only),
            .home_dir = home_dir,
            .nix_path = &.{},
            .builtins_attrs = undefined,
            .base_env = undefined,
            .import_cache = std.StringHashMap(*ast.Expr).init(alloc),
            .src_to_store = std.StringHashMap([]const u8).init(alloc),
            .err_trace = std.array_list.Managed(ast.Pos).init(alloc),
            .eval_chain = std.array_list.Managed(ast.Pos).init(alloc),
            .eq_seen = std.AutoHashMap(u64, void).init(alloc),
            .json_depth = 0,
        };
        // builtins + base env (mutually recursive construction)
        const b = try builtins.makeBuiltins(st);
        st.builtins_attrs = b.attrs;
        st.base_env = b.env;
        return st;
    }

    pub fn deinit(self: *EvalState) void {
        self.import_cache.deinit();
        self.src_to_store.deinit();
    }

    pub fn userError(self: *EvalState, comptime fmt: []const u8, args: anytype) EvalError {
        self.err_msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return error.OutOfMemory;
        self.err_kind = .other;
        self.err_active = true;
        return error.UserError;
    }

    pub fn userErrorKind(self: *EvalState, kind: @TypeOf(self.err_kind), comptime fmt: []const u8, args: anytype) EvalError {
        self.err_msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return error.OutOfMemory;
        self.err_kind = kind;
        self.err_active = true;
        return error.UserError;
    }

    // ------------------------------------------------------------------
    // Values
    // ------------------------------------------------------------------

    pub fn mkThunk(self: *EvalState, expr: *ast.Expr, env: *Env, pos: usize) EvalError!Value {
        const t = try self.alloc.create(value.Thunk);
        const st = try self.alloc.create(value.ThunkState);
        st.* = .{};
        t.* = .{ .expr = expr, .env = env, .state = st, .pos = pos };
        return .{ .thunk = t };
    }

    /// A lazy application: `fun arg0 arg1 ...` evaluated only when forced.
    /// Used by `map`/`mapAttrs` so element values stay lazy like Nix.
    pub fn mkLazyApply(self: *EvalState, fun: Value, args: []const *Value, pos: usize) EvalError!Value {
        const fun_copy = try self.alloc.create(Value);
        fun_copy.* = fun;
        const vars = try self.alloc.alloc(value.Var, 1 + args.len);
        vars[0] = .{ .name = "__zix_f", .value = fun_copy };
        for (args, 0..) |a, i| {
            vars[i + 1] = .{ .name = try std.fmt.allocPrint(self.alloc, "__zix_a{d}", .{i}), .value = a };
        }
        const env = try self.alloc.create(Env);
        env.* = .{ .parent = self.base_env, .vars = vars };
        var expr: *ast.Expr = try self.alloc.create(ast.Expr);
        expr.* = .{ .pos = .{}, .kind = .{ .var_ref = "__zix_f" } };
        for (args, 0..) |_, i| {
            const arg_ref = try self.alloc.create(ast.Expr);
            arg_ref.* = .{ .pos = .{}, .kind = .{ .var_ref = try std.fmt.allocPrint(self.alloc, "__zix_a{d}", .{i}) } };
            const app = try self.alloc.create(ast.Expr);
            app.* = .{ .pos = .{}, .kind = .{ .apply = .{ .fun = expr, .arg = arg_ref } } };
            expr = app;
        }
        return self.mkThunk(expr, env, pos);
    }

    pub fn mkString(self: *EvalState, s: []const u8, ctx: []const value.CtxElem) Value {
        _ = self;
        return .{ .string = .{ .s = s, .ctx = ctx } };
    }

    pub fn mkAttrs(self: *EvalState, items: []Item) EvalError!Value {
        // sort by name
        std.mem.sort(Item, items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        const a = try self.alloc.create(Attrs);
        a.* = .{ .items = items };
        return .{ .attrs = a };
    }

    /// Force a value to a non-thunk value (memoized).
    pub fn force(self: *EvalState, v: *Value) EvalError!void {
        while (true) {
            switch (v.*) {
                .thunk => |t| {
                    if (t.builtin) |b| {
                        // Lazy builtin application: run it on first force.
                        v.* = b.f(self, b.args, t.pos) catch |e| {
                            return e;
                        };
                        continue;
                    }


                    switch (t.state.phase) {
                        .evaluating => {
                            return error.InfiniteRecursion;
                        },
                        .done => {
                            // A thunk that (transitively) evaluates to itself
                            // is an infinite recursion, not a value.  Follow
                            // chains of done thunks (mutual recursion like
                            // `let y = z; z = y; in y`).
                            var cur = t.state.value;
                            var hops: usize = 0;
                            while (cur == .thunk and cur.thunk.state.phase == .done and hops < 16) : (hops += 1) {
                                if (cur.thunk.state == t.state) {
                                    return error.InfiniteRecursion;
                                }
                                cur = cur.thunk.state.value;
                            }
                            v.* = t.state.value;
                        },
                        .unevaluated => {
                            t.state.phase = .evaluating;
                            const val = try self.eval(t.expr, t.env, t.pos);
                            // Evaluating to a thunk that shares our state means
                            // the expression is self-referential.
                            if (val == .thunk and val.thunk.state == t.state) {
                                return error.InfiniteRecursion;
                            }
                            t.state.value = val;
                            t.state.phase = .done;
                            v.* = val;
                        },
                    }
                },
                else => return,
            }
        }
    }

    // ------------------------------------------------------------------
    // Environment lookup
    // ------------------------------------------------------------------

    pub fn lookup(self: *EvalState, env: *Env, name: []const u8) EvalError!*Value {
        // Nix resolves variables statically: lexical bindings always take
        // precedence over `with` scopes.  Emulate with two passes: first the
        // lexical chain, then `with` frames (innermost first).
        var e: ?*Env = env;
        while (e) |env_frame| {
            for (env_frame.vars) |v| {
                if (std.mem.eql(u8, v.name, name)) return v.value;
            }
            e = env_frame.parent;
        }
        e = env;
        while (e) |env_frame| {
            if (env_frame.with) |wv| {
                try self.force(wv);
                if (wv.* == .attrs) {
                    if (wv.attrs.find(name)) |item| return item;
                }
            }
            e = env_frame.parent;
        }
        return self.userError("undefined variable '{s}'", .{name});
    }

    // ------------------------------------------------------------------
    // Evaluation
    // ------------------------------------------------------------------

    pub fn eval(self: *EvalState, expr: *const ast.Expr, env: *Env, pos: usize) EvalError!Value {
        self.call_depth += 1;
        defer self.call_depth -= 1;
        // Nix's max-call-depth is ~9000-10000; keep ours a bit higher so we
        // never crash before the guard (deep recursion must be a clean error).
        if (self.call_depth > 20000) {
            return self.userError("stack overflow; max-call-depth exceeded", .{});
        }
        self.cur_pos = expr.pos;
        self.eval_chain.append(expr.pos) catch {};
        defer {
            if (!self.err_active and self.eval_chain.items.len > 0) _ = self.eval_chain.pop();
        }
        // Capture the position in the error trace: on error we unwind and
        // the innermost position is printed first.  Only record leaf-ish
        // nodes to keep the trace readable.
        const trace_depth = if (self.err_trace.items.len > 0) self.err_trace.items.len else 0;
        self.err_trace.append(expr.pos) catch {};
        defer {
            if (!self.err_active and self.err_trace.items.len > trace_depth) {
                _ = self.err_trace.pop();
            }
        }
        switch (expr.kind) {
            .int => |i| return .{ .int = i },
            .float => |f| return .{ .float = f },
            .path => |p| return .{ .path = .{ .p = p } },
            .pos => {
                // __curPos: null when no file position is available
                // (command-line expressions), like Nix.
                if (self.cur_file.len == 0) return .null_;
                const items = try self.alloc.alloc(Item, 3);
                items[0] = .{ .name = "column", .value = try self.alloc.create(Value) };
                items[0].value.* = .{ .int = self.cur_pos.col };
                items[1] = .{ .name = "file", .value = try self.alloc.create(Value) };
                items[1].value.* = self.mkString(self.cur_pos.file, &.{});
                items[2] = .{ .name = "line", .value = try self.alloc.create(Value) };
                items[2].value.* = .{ .int = self.cur_pos.line };
                return self.mkAttrs(items);
            },
            .import_path => |name| {
                const p = try self.findFile(name);
                return .{ .path = .{ .p = p } };
            },
            .str => |s| {
                var out = std.array_list.Managed(u8).init(self.alloc);
                var ctx = std.array_list.Managed(value.CtxElem).init(self.alloc);
                for (s.parts) |part| {
                    switch (part) {
                        .lit => |lit| try out.appendSlice(lit),
                        .interp => |e| {
                            var v = try self.evalAndForce(e, env, pos);
                            const t = try self.coerceToString(&v, &ctx, false, false, "while evaluating a path segment");
                            try out.appendSlice(t);
                        },
                    }
                }
                return self.mkString(try self.alloc.dupe(u8, out.items), ctx.items);
            },
            .var_ref => |name| {
                const v = try self.lookup(env, name);
                return v.*;
            },
            .select => |sel| {
                var base = try self.eval(sel.base, env, pos);
                try self.force(&base);
                var cur: *Value = &base;
                var first = true;
                for (sel.attrs) |elem| {
                    if (!first) try self.force(cur);
                    first = false;
                    const name: []const u8 = switch (elem) {
                        .static => |n| n,
                        .dyn => |e| blk: {
                            var dv = try self.eval(e, env, pos);
                            try self.force(&dv);
                            break :blk try self.coerceToPlainString(&dv, "while evaluating a dynamic attribute");
                        },
                    };
                    if (cur.* != .attrs) {
                        if (sel.default) |d| {
                            const defv = try self.eval(d, env, pos);
                            return defv;
                        }
                        return self.userError("cannot select attribute '{s}' from {s}", .{ name, showType(cur.*) });
                    }
                    const item = cur.attrs.find(name) orelse {
                        if (sel.default) |d| {
                            const defv = try self.eval(d, env, pos);
                            return defv;
                        }
                        return self.userError("attribute '{s}' missing", .{name});
                    };
                    cur = item;
                }
                return cur.*;
            },
            .has_attr => |ha| {
                var base = try self.eval(ha.base, env, pos);
                try self.force(&base);
                var cur: *Value = &base;
                var first = true;
                for (ha.attrs) |elem| {
                    if (!first) try self.force(cur);
                    first = false;
                    const name: []const u8 = switch (elem) {
                        .static => |n| n,
                        .dyn => |e| blk: {
                            var dv = try self.eval(e, env, pos);
                            try self.force(&dv);
                            break :blk try self.coerceToPlainString(&dv, "while evaluating a dynamic attribute");
                        },
                    };
                    if (cur.* != .attrs) return .{ .bool_ = false };
                    const item = cur.attrs.find(name) orelse return .{ .bool_ = false };
                    cur = item;
                }
                return .{ .bool_ = true };
            },
            .apply => |app| {
                const fun = try self.eval(app.fun, env, pos);
                const arg = try self.alloc.create(Value);
                arg.* = try self.mkThunk(app.arg, env, pos);
                return self.apply(fun, arg, pos);
            },
            .op => |op| switch (op.kind) {
                .eq, .neq => {
                    const l = try self.eval(op.left, env, pos);
                    const r = try self.eval(op.right, env, pos);
                    const eq = try self.eqValues(l, r);
                    return .{ .bool_ = if (op.kind == .eq) eq else !eq };
                },
                .and_, .or_, .impl => {
                    const l = try self.evalBool(op.left, env, pos, "in the left operand of the AND (&&) operator");
                    const b: bool = switch (op.kind) {
                        .and_ => blk: {
                            if (!l) break :blk false;
                            break :blk try self.evalBool(op.right, env, pos, "in the right operand of the AND (&&) operator");
                        },
                        .or_ => blk: {
                            if (l) break :blk true;
                            break :blk try self.evalBool(op.right, env, pos, "in the right operand of the OR (||) operator");
                        },
                        .impl => blk: {
                            if (!l) break :blk true;
                            break :blk try self.evalBool(op.right, env, pos, "in the right operand of the IMPL (->) operator");
                        },
                        else => unreachable,
                    };
                    return .{ .bool_ = b };
                },
                .update => {
                    var l = try self.eval(op.left, env, pos);
                    try self.force(&l);
                    var r = try self.eval(op.right, env, pos);
                    try self.force(&r);
                    if (l != .attrs or r != .attrs) {
                        return self.userError("the '//' operator is only defined on attribute sets", .{});
                    }
                    return self.mergeAttrs(l.attrs, r.attrs);
                },
                .concat_lists => {
                    var l = try self.eval(op.left, env, pos);
                    try self.force(&l);
                    var r = try self.eval(op.right, env, pos);
                    try self.force(&r);
                    if (l != .list or r != .list) {
                        return self.userError("the '++' operator is only defined on lists", .{});
                    }
                    const out = try self.alloc.alloc(*Value, l.list.len + r.list.len);
                    @memcpy(out[0..l.list.len], l.list);
                    @memcpy(out[l.list.len..], r.list);
                    return .{ .list = out };
                },
            },
            .concat => |c| return self.evalConcat(c.parts, env, pos),
            .not_ => |e| {
                const b = try self.evalBool(e, env, pos, "in the argument of the ! operator");
                return .{ .bool_ = !b };
            },
            .call_builtin => |cb| {
                const b = self.builtins_attrs.find(cb.name) orelse {
                    return self.userError("unknown builtin '{s}'", .{cb.name});
                };
                var res: Value = b.*;
                for (cb.args) |a| {
                    const arg_val = try self.alloc.create(Value);
                    arg_val.* = try self.mkThunk(a, env, pos);
                    res = try self.apply(res, arg_val, pos);
                }
                return res;
            },
            .attrset => |aset| return self.evalAttrset(aset.binds, aset.recursive, env, pos),
            .let_rec => |lr| {
                // `let binds in body`  ≡  (rec { binds; body = body; }).body
                const all_binds = try self.alloc.alloc(ast.AttrBind, lr.binds.len + 1);
                @memcpy(all_binds[0..lr.binds.len], lr.binds);
                const body_bind = try self.alloc.create(ast.AttrBind);
                const body_path = try self.alloc.alloc(ast.AttrElem, 1);
                body_path[0] = .{ .static = "body" };
                body_bind.* = .{ .path = body_path, .value = lr.body, .inherit_from = null };
                all_binds[lr.binds.len] = body_bind.*;
                const aset_val = try self.evalAttrset(all_binds, true, env, pos);
                if (aset_val != .attrs) return error.BadType;
                const item = aset_val.attrs.find("body") orelse {
                    return self.userError("attribute 'body' missing", .{});
                };
                return item.*;
            },
            .with_ => |w| {
                const attrs_val = try self.eval(w.attrs, env, pos);
                const frame = try self.alloc.create(Env);
                frame.* = .{ .parent = env, .vars = &.{}, .with = try self.alloc.create(Value) };
                frame.with.?.* = attrs_val;
                return self.eval(w.body, frame, pos);
            },
            .if_ => |i| {
                const cond = try self.evalBool(i.cond, env, pos, "in the condition of the if expression");
                if (cond) {
                    return self.eval(i.then, env, pos);
                } else {
                    return self.eval(i.else_, env, pos);
                }
            },
            .assert_ => |a| {
                const cond = try self.evalBool(a.cond, env, pos, "in the assertion");
                if (!cond) {
                    return self.userErrorKind(.assert, "assertion failed", .{});
                }
                return self.eval(a.body, env, pos);
            },
            .lambda => |lam| {
                const l = try self.alloc.create(value.Lambda);
                l.* = .{ .params = lam, .env = env, .pos = lam.pos };
                return .{ .lambda = l };
            },
            .list => |elems| {
                const out = try self.alloc.alloc(*Value, elems.len);
                for (elems, 0..) |e, i| {
                    out[i] = try self.alloc.create(Value);
                    // Evaluate the element expression like Nix: operators and
                    // variables are checked eagerly (undefined variables
                    // error), while calls stay lazy (builtins run on force).
                    out[i].* = try self.eval(e, env, pos);
                }
                return .{ .list = out };
            },
        }
    }

    pub fn evalBool(self: *EvalState, expr: *const ast.Expr, env: *Env, pos: usize, comptime what: []const u8) EvalError!bool {
        _ = what;
        var v = try self.eval(expr, env, pos);
        try self.force(&v);
        switch (v) {
            .bool_ => |b| return b,
            else => return self.userError("value is {s} while a Boolean was expected", .{showType(v)}),
        }
    }

    pub fn showType(v: Value) []const u8 {
        return switch (v) {
            .int => "an integer",
            .float => "a float",
            .bool_ => "a Boolean",
            .null_ => "null",
            .string => "a string",
            .path => "a path",
            .list => "a list",
            .attrs => "a set",
            .lambda => "a function",
            .builtin => "a function",
            .thunk => "a thunk",
        };
    }

    /// Evaluate and force a value.
    pub fn evalAndForce(self: *EvalState, expr: *const ast.Expr, env: *Env, pos: usize) EvalError!Value {
        var v = try self.eval(expr, env, pos);
        try self.force(&v);
        return v;
    }

    // ------------------------------------------------------------------
    // Function application
    // ------------------------------------------------------------------

    pub fn apply(self: *EvalState, fun: Value, arg: *Value, pos: usize) EvalError!Value {
        var f = fun;
        try self.force(&f);
        switch (f) {
            .builtin => |b| {
                if (b.args.len + 1 == b.arity) {
                    // full application: collect the args; Nix applies
                    // builtins lazily (the call runs on first force).
                    const args = try self.alloc.alloc(*Value, b.args.len + 1);
                    @memcpy(args[0..b.args.len], b.args);
                    args[b.args.len] = arg;
                    const t = try self.alloc.create(value.Thunk);
                    const ts = try self.alloc.create(value.ThunkState);
                    ts.* = .{};
                    t.* = .{ .expr = undefined, .env = undefined, .state = ts, .pos = pos, .builtin = .{ .name = b.name, .arity = b.arity, .args = args, .f = b.f } };
                    return .{ .thunk = t };
                }
                // partial application: return a new builtin with one more arg
                const nb = try self.alloc.create(value.Builtin);
                const args = try self.alloc.alloc(*Value, b.args.len + 1);
                @memcpy(args[0..b.args.len], b.args);
                args[b.args.len] = arg;
                nb.* = .{ .name = b.name, .arity = b.arity, .args = args, .f = b.f };
                return .{ .builtin = nb.* };
            },
            .lambda => |lam| return self.callLambda(lam, arg, pos),
            .attrs => {
                // Sets with a `__functor` attribute can be called as functions
                // (`__functor self arg`), like Nix.
                if (f.attrs.find("__functor")) |functor| {
                    // `set arg` == `set.__functor set arg` (the functor receives
                    // the set itself, like Nix).
                    const functor_v = functor.*;
                    var self_v: Value = f;
                    const r1 = try self.apply(functor_v, &self_v, pos);
                    return self.apply(r1, arg, pos);
                }
                return self.userError("attempt to call something which is not a function but a set", .{});
            },
            else => return self.userError("attempt to call something which is not a function but {s}", .{showType(f)}),
        }
    }

    pub fn callLambda(self: *EvalState, lam: *value.Lambda, arg: *Value, pos: usize) EvalError!Value {
        const params = lam.params;
        if (params.arg) |name| {
            const vars = try self.alloc.alloc(Var, 1);
            vars[0] = .{ .name = name, .value = arg };
            const env = try self.alloc.create(Env);
            env.* = .{ .parent = lam.env, .vars = vars };
            return self.eval(params.body, env, pos);
        }
        const formals = params.formals.?;
        // Force the argument to an attrset (heap-allocated so it can be
        // captured by lazy closures).
        const av = try self.alloc.create(Value);
        av.* = arg.*;
        try self.force(av);
        if (av.* != .attrs) {
            return self.userError("function called with unexpected argument (expected a set)", .{});
        }
        const arg_attrs = av.attrs;
        // Nix binds *all* formals in one scope, so a default may reference any
        // other formal (earlier or later, e.g. `{ a ? b, b ? 2 }: a`).  Create
        // the slots and env first, then fill defaults as thunks over that env.
        const var_count = formals.formals.len + @intFromBool(params.arg_name != null);
        const vars = try self.alloc.alloc(Var, var_count);
        var vi: usize = 0;
        if (params.arg_name) |name| {
            vars[vi] = .{ .name = name, .value = av };
            vi += 1;
        }
        const fenv = try self.alloc.create(Env);
        fenv.* = .{ .parent = lam.env, .vars = vars[0..vi] }; // placeholder; filled below
        for (formals.formals) |formal| {
            const slot = try self.alloc.create(Value);
            vars[vi] = .{ .name = formal.name, .value = slot };
            vi += 1;
        }
        fenv.vars = vars[0..vi];
        vi = @intFromBool(params.arg_name != null);
        for (formals.formals) |formal| {
            const slot = vars[vi].value;
            vi += 1;
            if (arg_attrs.find(formal.name)) |item| {
                slot.* = item.*;
            } else if (formal.default) |d| {
                slot.* = try self.mkThunk(d, fenv, pos);
            } else {
                return self.userError("function 'anonymous lambda' called without required argument '{s}'", .{formal.name});
            }
        }
        if (!formals.ellipsis) {
            for (arg_attrs.items) |item| {
                var found = false;
                for (formals.formals) |formal| {
                    if (std.mem.eql(u8, formal.name, item.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return self.userError("function called with unexpected argument '{s}'", .{item.name});
                }
            }
        }
        return self.eval(params.body, fenv, pos);
    }

    // ------------------------------------------------------------------
    // Attrsets
    // ------------------------------------------------------------------

    fn evalAttrset(self: *EvalState, binds: []const ast.AttrBind, recursive: bool, env: *Env, pos: usize) EvalError!Value {
        // 1. Resolve dynamic names and group binds by first path element.
        const Group = struct {
            name: []const u8,
            value_expr: ?*ast.Expr,
            inherit_from: ?*ast.Expr,
            rest: std.array_list.Managed(ast.AttrBind),
            pos: ast.Pos = .{},
        };
        var groups = std.array_list.Managed(Group).init(self.alloc);
        var skip_bind = false;
        var names = std.array_list.Managed([]const u8).init(self.alloc);
        for (binds) |bind| {
            const gpos = bind.pos;
            const dyn_name = switch (bind.path[0]) {
                .static => |n| n,
                .dyn => |e| blk: {
                    var dv = try self.evalAndForce(e, env, pos);
                    // `{ ${null} = ...; }` — the attribute is dropped (like Nix).
                    if (dv == .null_) skip_bind = true;
                    break :blk if (dv == .null_) "" else try self.coerceToPlainString(&dv, "while evaluating a dynamic attribute");
                },
            };
            if (skip_bind) {
                skip_bind = false;
                continue;
            }
            const name: []const u8 = dyn_name;
            var rest_binds: []const ast.AttrBind = &.{};
            if (bind.path.len > 1) {
                // nested: a.b.c — represent rest as a bind with path[1..]
                const nb = try self.alloc.create(ast.AttrBind);
                nb.* = .{ .path = bind.path[1..], .value = bind.value, .inherit_from = bind.inherit_from, .pos = bind.pos };
                rest_binds = @constCast(&[_]ast.AttrBind{nb.*});
            }
            var found: ?usize = null;
            for (names.items, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) {
                    found = i;
                    break;
                }
            }
            if (found) |gi| {
                if (rest_binds.len > 0) {
                    try groups.items[gi].rest.append(rest_binds[0]);
                } else {
                    if (groups.items[gi].value_expr != null) return error.DuplicateAttr;
                    groups.items[gi].value_expr = bind.value;
                    groups.items[gi].inherit_from = bind.inherit_from;
                }
            } else {
                var g = Group{
                    .name = name,
                    .value_expr = null,
                    .inherit_from = null,
                    .rest = std.array_list.Managed(ast.AttrBind).init(self.alloc),
                    .pos = gpos,
                };
                if (rest_binds.len > 0) {
                    try g.rest.append(rest_binds[0]);
                } else {
                    g.value_expr = bind.value;
                    g.inherit_from = bind.inherit_from;
                }
                try groups.append(g);
                try names.append(name);
            }
        }

        // 2. Build items: each group → one item whose value is a thunk.
        const items = try self.alloc.alloc(Item, groups.items.len);
        for (groups.items, 0..) |g, i| {
            items[i] = .{ .name = g.name, .value = try self.alloc.create(Value), .pos = g.pos };
        }
        var rec_env: ?*Env = null;
        if (recursive) {
            const frame = try self.alloc.create(Env);
            const vars = try self.alloc.alloc(Var, items.len);
            for (items, 0..) |it, i| {
                vars[i] = .{ .name = it.name, .value = items[i].value };
            }
            frame.* = .{ .parent = env, .vars = vars };
            rec_env = frame;
        }
        for (groups.items, 0..) |g, i| {
            const item_env = rec_env orelse env;
            const e = try self.alloc.create(ast.Expr);
            if (g.rest.items.len > 0) {
                e.* = .{ .pos = g.pos, .kind = .{ .attrset = .{ .binds = g.rest.items, .recursive = recursive } } };
                items[i].value.* = try self.mkThunk(e, item_env, pos);
            } else if (g.inherit_from) |from| {
                // inherit (x) name → select
                const sel = try self.alloc.create(ast.Expr);
                const sel_attrs = try self.alloc.alloc(ast.AttrElem, 1);
                sel_attrs[0] = .{ .static = g.name };
                sel.* = .{ .pos = g.pos, .kind = .{ .select = .{ .base = from, .attrs = sel_attrs, .default = null } } };
                // The inherit-from expression must see the recursive bindings
                // (e.g. `inherit (lib) ...` inside a `let lib = ...; in ...`).
                items[i].value.* = try self.mkThunk(sel, item_env, pos);
            } else {
                items[i].value.* = try self.mkThunk(g.value_expr.?, item_env, pos);
            }
        }

        const attrs = try self.alloc.create(Attrs);
        std.mem.sort(Item, items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        attrs.* = .{ .items = items, .rec_env = rec_env };
        return .{ .attrs = attrs };
    }

    pub fn mergeAttrs(self: *EvalState, a: *Attrs, b: *Attrs) EvalError!Value {
        // merge, right wins
        var items = std.array_list.Managed(Item).init(self.alloc);
        for (a.items) |it| try items.append(it);
        for (b.items) |bit| {
            var replaced = false;
            for (items.items) |*it| {
                if (std.mem.eql(u8, it.name, bit.name)) {
                    it.value = bit.value;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try items.append(bit);
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, x: Item, y: Item) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        const attrs = try self.alloc.create(Attrs);
        attrs.* = .{ .items = items.items };
        return .{ .attrs = attrs };
    }

    // ------------------------------------------------------------------
    // String concatenation (ExprConcatStrings)
    // ------------------------------------------------------------------

    pub fn evalConcat(self: *EvalState, parts: []const *ast.Expr, env: *Env, pos: usize) EvalError!Value {
        if (parts.len == 0) return self.mkString("", &.{});
        var first_type: ?std.meta.Tag(Value) = null;
        var int_sum: i64 = 0;
        var float_sum: f64 = 0;
        var out = std.array_list.Managed(u8).init(self.alloc);
        var ctx = std.array_list.Managed(value.CtxElem).init(self.alloc);
        for (parts) |p| {
            var v = try self.evalAndForce(p, env, pos);
            if (first_type == null) {
                first_type = std.meta.activeTag(v);
                switch (v) {
                    .int => |i| {
                        int_sum = i;
                        continue;
                    },
                    .float => |f| {
                        float_sum = f;
                        continue;
                    },
                    else => {},
                }
            }
            switch (first_type.?) {
                .int => switch (v) {
                    .int => |i| {
                        int_sum = std.math.add(i64, int_sum, i) catch {
                            return self.userError("integer overflow in adding {d} + {d}", .{ int_sum, i });
                        };
                    },
                    .float => |f| {
                        float_sum = @as(f64, @floatFromInt(int_sum)) + f;
                        first_type = .float;
                    },
                    else => return self.userError("cannot add {s} to an integer", .{showType(v)}),
                },
                .float => switch (v) {
                    .int => |i| float_sum += @floatFromInt(i),
                    .float => |f| float_sum += f,
                    else => return self.userError("cannot add {s} to a float", .{showType(v)}),
                },
                else => {
                    const s = try self.coerceToString(&v, &ctx, false, false, "while evaluating a path segment");
                    try out.appendSlice(s);
                },
            }
        }
        switch (first_type.?) {
            .int => return .{ .int = int_sum },
            .float => return .{ .float = float_sum },
            .path => {
                if (ctx.items.len > 0) {
                    return self.userError("a string that refers to a store path cannot be appended to a path", .{});
                }
                return .{ .path = .{ .p = try self.alloc.dupe(u8, out.items) } };
            },
            else => return self.mkString(try self.alloc.dupe(u8, out.items), ctx.items),
        }
    }

    /// Nix `coerceToString`.  With `coerce_more=false` (string interpolation,
    /// `+` on strings) only strings and paths are accepted; `toString` and
    /// derivation attributes use `coerce_more=true`.
    pub fn coerceToString(self: *EvalState, v: *Value, ctx: *std.array_list.Managed(value.CtxElem), copy_to_store: bool, coerce_more: bool, err_ctx: []const u8) EvalError![]const u8 {
        try self.force(v);
        switch (v.*) {
            .string => |s| {
                try ctx.appendSlice(s.ctx);
                return s.s;
            },
            .path => |p| {
                if (copy_to_store) {
                    const sp = try self.copyPathToStore(p.p);
                    try ctx.append(.{ .kind = .opaq, .path = sp });
                    return sp;
                }
                try ctx.appendSlice(p.ctx);
                return p.p;
            },
            .attrs => |a| {
                // derivation-like set: use outPath
                if (a.find("outPath")) |op| {
                    var ov = op.*;
                    return self.coerceToString(&ov, ctx, copy_to_store, coerce_more, err_ctx);
                }
                var nm = std.array_list.Managed(u8).init(self.alloc);
                for (a.items[0..@min(a.items.len, 8)]) |it| {
                    nm.appendSlice(it.name) catch {};
                    nm.append(' ') catch {};
                }
                return self.userError("cannot coerce {s} to a string: {s}", .{ showType(v.*), err_ctx });
            },
            else => {
                if (!coerce_more) {
                    return self.userError("cannot coerce {s} to a string: {s}", .{ showType(v.*), err_ctx });
                }
                switch (v.*) {
                    .int => |i| return std.fmt.allocPrint(self.alloc, "{d}", .{i}),
                    .float => |f| return std.fmt.allocPrint(self.alloc, "{d:.6}", .{f}),
                    .bool_ => |b| return if (b) "1" else "",
                    .null_ => return "",
                    .list => |l| {
                        var out = std.array_list.Managed(u8).init(self.alloc);
                        for (l, 0..) |elem, i| {
                            if (i > 0) try out.append(' ');
                            var e = elem.*;
                            const s = try self.coerceToString(&e, ctx, copy_to_store, coerce_more, err_ctx);
                            try out.appendSlice(s);
                        }
                        return self.alloc.dupe(u8, out.items);
                    },
                    else => return self.userError("cannot coerce {s} to a string: {s}", .{ showType(v.*), err_ctx }),
                }
            },
        }
    }

    pub fn coerceToPlainString(self: *EvalState, v: *Value, err_ctx: []const u8) EvalError![]const u8 {
        var ctx = std.array_list.Managed(value.CtxElem).init(self.alloc);
        return self.coerceToString(v, &ctx, false, false, err_ctx);
    }

    /// Loose string coercion (ints/floats/bools/null/lists allowed), used
    /// where Nix passes coerceMore=true (e.g. genericClosure keys).
    pub fn coerceToLooseString(self: *EvalState, v: *Value, err_ctx: []const u8) EvalError![]const u8 {
        var ctx = std.array_list.Managed(value.CtxElem).init(self.alloc);
        return self.coerceToString(v, &ctx, false, true, err_ctx);
    }

    /// Evaluate a value but swallow errors (for `builtins.tryEval`).
    pub fn tryEval(self: *EvalState, v: *Value) EvalError!Value {
        const saved_err = self.err_msg;
        var vv = v.*;
        self.force(&vv) catch |e| {
            // keep err_kind so builtins.tryEval can distinguish
            // assert/throw (caught) from other errors (propagated)
            self.err_msg = saved_err;
            return e;
        };
        return vv;
    }

    // ------------------------------------------------------------------
    // Deep equality
    // ------------------------------------------------------------------

    pub fn eqValues(self: *EvalState, a: Value, b: Value) EvalError!bool {
        self.eq_depth += 1;
        defer self.eq_depth -= 1;
        // A value is trivially equal to itself (same object).
        if (std.meta.activeTag(a) == .attrs and std.meta.activeTag(b) == .attrs and a.attrs == b.attrs) return true;
        // Cycle detection: comparing a cyclic structure (e.g. the
        // makeOverridable `all` output chain) would recurse forever.  A
        // revisited *distinct* pair means the structures differ only by their
        // cycles, so they are not equal.
        if (std.meta.activeTag(a) == .attrs and std.meta.activeTag(b) == .attrs) {
            const key = @intFromPtr(a.attrs) *% 0x9E3779B1 +% @intFromPtr(b.attrs);
            if (self.eq_seen.contains(key)) return false;
            self.eq_seen.put(key, {}) catch {};
            defer _ = self.eq_seen.remove(key);
        }
        if (self.eq_depth > 100000) return false;
        var av = a;
        var bv = b;
        try self.force(&av);
        try self.force(&bv);
        // Same forced object on both sides: trivially equal (this also
        // terminates comparisons of cyclic structures with themselves).
        if (std.meta.activeTag(av) == .attrs and std.meta.activeTag(bv) == .attrs and av.attrs == bv.attrs) return true;
        switch (av) {
            .int => |i| return switch (bv) {
                .int => |j| i == j,
                .float => |f| @as(f64, @floatFromInt(i)) == f,
                else => false,
            },
            .float => |f| return switch (bv) {
                .int => |j| f == @as(f64, @floatFromInt(j)),
                .float => |g| f == g,
                else => false,
            },
            .bool_ => |x| return bv == .bool_ and x == bv.bool_,
            .null_ => return bv == .null_,
            .string => |s| {
                return switch (bv) {
                    .string => |t| std.mem.eql(u8, s.s, t.s),
                    .path => |p| std.mem.eql(u8, s.s, p.p),
                    else => false,
                };
            },
            .path => |p| return switch (bv) {
                .path => |q| std.mem.eql(u8, p.p, q.p),
                .string => |s| std.mem.eql(u8, p.p, s.s),
                else => false,
            },
            .list => |l1| {
                if (bv != .list or l1.len != bv.list.len) return false;
                for (l1, 0..) |e, i| {
                    if (!try self.eqValues(e.*, bv.list[i].*)) return false;
                }
                return true;
            },
            .attrs => |a1| {
                if (bv != .attrs) return false;
                const a2 = bv.attrs;
                if (a1.items.len != a2.items.len) return false;
                for (a1.items, 0..) |it, i| {
                    if (!std.mem.eql(u8, it.name, a2.items[i].name)) return false;
                    if (!try self.eqValues(it.value.*, a2.items[i].value.*)) return false;
                }
                return true;
            },
            .lambda => |l1| return switch (bv) {
                .lambda => |l2| l1 == l2,
                else => false,
            },
            .builtin => |b1| return switch (bv) {
                .builtin => |b2| @intFromPtr(b1.f) == @intFromPtr(b2.f),
                else => false,
            },
            .thunk => unreachable, // forced above
        }
    }

    // ------------------------------------------------------------------
    // Files, import, store
    // ------------------------------------------------------------------

    pub fn findFile(self: *EvalState, name: []const u8) EvalError![]const u8 {
        // Core packages (`nix/...`) are served from embedded Nix sources.
        if (std.mem.startsWith(u8, name, "nix/")) {
            if (std.mem.eql(u8, name, "nix/fetchurl.nix")) {
                const resolved = try std.fs.path.join(self.alloc, &.{ self.corepkgs_dir, "fetchurl.nix" });
                fsutil.writeFile(resolved, builtins.fetchurl_nix_src) catch {};
                return resolved;
            }
            // `nix/derivation.nix` is handled by the builtin `derivation`.
            return self.userErrorKind(.thrown, "cannot find '{s}' in the search path", .{name});
        }
        for (self.nix_path) |entry| {
            const prefix = if (entry.prefix.len > 0) entry.prefix else std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, prefix, name) or
                (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len and name[prefix.len] == '/'))
            {
                const rest = name[prefix.len..];
                const joined = try std.fs.path.join(self.alloc, &.{ entry.path, rest });
                return joined;
            }
        }
        // Nix raises ThrownError here, so `builtins.tryEval` catches it.
        return self.userErrorKind(.thrown, "cannot find '{s}' in the search path", .{name});
    }

    /// Resolve a path value for reading/import: directories get default.nix.
    fn resolveExprPath(self: *EvalState, p: []const u8) EvalError![]const u8 {
        if (fsutil.isDirectory(p)) {
            return std.fs.path.join(self.alloc, &.{ p, "default.nix" });
        }
        return p;
    }

    /// Parse a file and evaluate it in the base environment.
    pub fn parseFile(self: *EvalState, p: []const u8) EvalError!*ast.Expr {
        const contents = fsutil.readFileAlloc(self.alloc, p, 1 << 30) catch |e| {
            return self.userError("cannot read '{s}': {s}", .{ p, @errorName(e) });
        };
        return self.parse(contents, p);
    }

    /// import: read + parse + evaluate a file.
    pub fn importPath(self: *EvalState, p: []const u8) EvalError!Value {
        const resolved = try self.resolveExprPath(p);
        const parsed = try self.parseFile(resolved);
        const prev_file = self.cur_file;
        self.cur_file = resolved;
        defer self.cur_file = prev_file;
        return self.eval(parsed, self.base_env, 0);
    }

    pub fn parse(self: *EvalState, contents: []const u8, file: []const u8) EvalError!*ast.Expr {
        var lx = lexer.Lexer.init(self.alloc, contents);
        const toks = lx.lexAll() catch |e| {
            return self.userError("parse error in '{s}': {s}", .{ file, @errorName(e) });
        };
        const dirname = std.fs.path.dirname(file) orelse "";
        const base_dir = if (dirname.len > 0) dirname else ".";
        var p = parser.Parser.init(self.alloc, toks, base_dir, self.home_dir);
        p.file = file;
        return p.parse() catch |e| {
            const pos = p.curPos();
            return self.userError("parse error in '{s}': {s} at «{s}»:{d}:{d}", .{ file, @errorName(e), file, pos.line, pos.col });
        };
    }

    /// Copy a filesystem path into the store (recursive sha256).
    pub fn copyPathToStore(self: *EvalState, p: []const u8) EvalError![]const u8 {
        if (self.src_to_store.get(p)) |cached| return cached;
        const name = std.fs.path.basename(p);
        const sp = store.addPathToStore(&self.store, name, p) catch |e| {
            return self.userError("cannot copy '{s}' to the store: {s}", .{ p, @errorName(e) });
        };
        try self.src_to_store.put(p, sp);
        return sp;
    }
};
