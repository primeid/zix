//! Runtime values for the Nix evaluator: lazy values (thunks),
//! environments, closures, attrsets.

const std = @import("std");
const ast = @import("ast.zig");
const eval = @import("eval.zig");

pub const CtxKind = enum { opaq, drv_out, drv_deep };

pub const CtxElem = struct {
    kind: CtxKind,
    /// store path: for `opaque` the path itself; for `built`/`drvdeep` the
    /// derivation's store path
    path: []const u8,
    /// output name, for `built` context elements
    output: []const u8 = "",
};

pub const StringVal = struct {
    s: []const u8,
    /// derivation context: store paths referenced by this string
    ctx: []const CtxElem = &.{},
};

pub const PathVal = struct {
    p: []const u8,
    ctx: []const CtxElem = &.{},
};

pub const Builtin = struct {
    name: []const u8,
    arity: usize,
    /// arguments collected so far (for curried application)
    args: []const *Value = &.{},
    f: *const fn (st: *eval.EvalState, args: []const *Value, pos: usize) eval.EvalError!Value,
};

pub const Lambda = struct {
    params: ast.Lambda,
    env: *Env,
    pos: ast.Pos = .{},
};

pub const Thunk = struct {
    expr: *ast.Expr,
    env: *Env,
    state: enum { unevaluated, evaluating, done } = .unevaluated,
    value: Value = .null_,
    pos: usize = 0,
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool_: bool,
    null_,
    string: StringVal,
    path: PathVal,
    list: []const *Value,
    attrs: *Attrs,
    lambda: *Lambda,
    builtin: Builtin,
    thunk: *Thunk,
};

pub const Item = struct {
    name: []const u8,
    value: *Value,
    /// source position of the attribute binding (for builtins.unsafeGetAttrPos)
    pos: ast.Pos = .{},
};

/// Attribute set with items sorted by name.  `rec_env` is the frame used
/// for recursive self-reference (`rec`, `let`).
pub const Attrs = struct {
    items: []Item,
    rec_env: ?*Env = null,

    pub fn find(self: *const Attrs, name: []const u8) ?*Value {
        // binary search on sorted items
        var lo: usize = 0;
        var hi: usize = self.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const ord = std.mem.order(u8, self.items[mid].name, name);
            if (ord == .eq) return self.items[mid].value;
            if (ord == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }
};

pub const Var = struct {
    name: []const u8,
    value: *Value,
};

pub const Env = struct {
    parent: ?*Env,
    vars: []const Var,
    /// `with` attrset value (possibly a thunk), or null
    with: ?*Value = null,

    pub fn init(parent: ?*Env, vars: []const Var) Env {
        return .{ .parent = parent, .vars = vars };
    }
};
